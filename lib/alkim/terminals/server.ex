defmodule Alkim.Terminals.Server do
  @moduledoc """
  Owns one interactive harness process through `priv/bin/alkim-pty`.

  The helper holds the pseudo-terminal; this process holds the helper. That
  ordering is what keeps a TUI supervised: if this process dies the port
  closes, the helper sees EOF on stdin and kills the harness, so no agent is
  ever left running unattended.

  Two things make a terminal different from a session:

    * **Output is bytes, not events.** They are broadcast verbatim and kept
      in a bounded scrollback so a browser that reconnects sees what it
      missed. Nothing tries to interpret them.
    * **Output is bursty.** A TUI repaints constantly, so chunks are
      coalesced on a short timer instead of broadcasting every read.
  """

  use GenServer, restart: :temporary

  alias Alkim.Terminals
  alias Alkim.Terminals.Log

  # Enough to redraw a large window and keep some history, small enough that
  # idle terminals cost nothing worth measuring.
  @scrollback_bytes 256 * 1024
  @flush_ms 16
  @default_size {24, 80}

  # A harness that cannot continue a conversation usually says so and exits
  # at once. Within this window a failed resume is treated as "there was
  # nothing to resume" rather than as the terminal being over.
  @resume_grace_ms 8_000

  # How long a harness gets to quit its own way before it is signalled.
  @quit_grace_ms 6_000

  defmodule State do
    @moduledoc false
    defstruct [
      :terminal,
      :port,
      :pending,
      :flush_timer,
      :log,
      :launch,
      :started_ms,
      resumed?: false,
      retried?: false,
      stopping?: false,
      log_bytes: 0,
      scrollback: [],
      scrollback_bytes: 0,
      size: {24, 80}
    ]
  end

  ## API

  def start_link(opts) do
    terminal = Keyword.fetch!(opts, :terminal)
    GenServer.start_link(__MODULE__, opts, name: Terminals.Registry.via(terminal.id))
  end

  @doc "Sends raw keystrokes to the terminal."
  def send_keys(pid, data) when is_binary(data), do: GenServer.cast(pid, {:keys, data})

  @doc "Tells the pseudo-terminal its window changed, so the TUI repaints to fit."
  def resize(pid, rows, cols) when is_integer(rows) and is_integer(cols),
    do: GenServer.cast(pid, {:resize, rows, cols})

  @doc "The terminal plus everything in its scrollback, for a client that (re)attaches."
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  @doc "Asks the harness to exit; the helper escalates if it will not."
  def stop(pid), do: GenServer.call(pid, :stop)

  ## Callbacks

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    terminal = Keyword.fetch!(opts, :terminal)
    log = if Keyword.get(opts, :save_output, true), do: open_log(terminal.id)

    state = %State{terminal: terminal, size: @default_size, log: log}
    {:ok, state, {:continue, {:spawn, Keyword.fetch!(opts, :launch)}}}
  end

  defp open_log(id) do
    case Log.open(id) do
      {:ok, device} -> device
      :error -> nil
    end
  end

  @impl true
  def handle_continue({:spawn, launch}, state) do
    {rows, cols} = state.size

    port =
      Port.open({:spawn_executable, helper()}, [
        :binary,
        :exit_status,
        {:packet, 4},
        args: [launch.executable | launch.args],
        cd: state.terminal.workspace,
        env: env(launch)
      ])

    state = %{
      state
      | port: port,
        launch: launch,
        resumed?: resumed?(launch),
        started_ms: System.monotonic_time(:millisecond)
    }

    Port.command(port, <<?r, rows::16, cols::16>>)

    {:noreply, update(state, status: :running, started_at: DateTime.utc_now())}
  end

  # Only Claude Code echoes back a chosen id; for the others a resume is an
  # argument we passed, so ask the adapter's own args.
  defp resumed?(launch), do: Enum.any?(launch.args, &(&1 in ["--resume", "resume"]))

  @impl true
  def handle_cast({:keys, data}, %State{port: port} = state) when is_port(port) do
    Port.command(port, <<?d>> <> data)
    {:noreply, state}
  end

  def handle_cast({:resize, rows, cols}, %State{port: port} = state) when is_port(port) do
    if {rows, cols} == state.size do
      {:noreply, state}
    else
      Port.command(port, <<?r, rows::16, cols::16>>)
      {:noreply, %{state | size: {rows, cols}}}
    end
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:snapshot, _from, state) do
    state = flush(state)
    {:reply, {state.terminal, replayable(state)}, state}
  end

  # Ask the harness to quit the way it expects, so it keeps its conversation;
  # signal it only if it will not go.
  def handle_call(:stop, _from, %State{port: port} = state) when is_port(port) do
    case quit_sequence(state.terminal.harness) do
      nil ->
        Port.command(port, <<?k>>)

      keys ->
        Port.command(port, <<?d>> <> keys)
        Process.send_after(self(), :force_stop, @quit_grace_ms)
    end

    {:reply, :ok, %{state | stopping?: true}}
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, state}

  # Prefer what is on disk: it holds more history than the in-memory buffer,
  # and it is what a client would get after a restart anyway.
  defp replayable(%State{log: nil} = state),
    do: state.scrollback |> Enum.reverse() |> IO.iodata_to_binary()

  defp replayable(state) do
    case Log.read(state.terminal.id) do
      "" -> state.scrollback |> Enum.reverse() |> IO.iodata_to_binary()
      saved -> saved
    end
  end

  @impl true
  def handle_info({port, {:data, <<?o, chunk::binary>>}}, %State{port: port} = state) do
    {:noreply, state |> keep(chunk) |> buffer(chunk) |> schedule_flush()}
  end

  def handle_info({port, {:data, <<?x, code::32>>}}, %State{port: port} = state) do
    {:noreply, finish(state, code)}
  end

  def handle_info({port, {:data, _other}}, %State{port: port} = state), do: {:noreply, state}

  # The helper exits right after reporting the status; if it dies first, the
  # terminal still has to stop cleanly.
  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    {:stop, :normal, finish(%{state | port: nil}, state.terminal.exit_code || code)}
  end

  def handle_info(:flush, state), do: {:noreply, flush(%{state | flush_timer: nil})}

  def handle_info(:force_stop, %State{port: port} = state) when is_port(port) do
    Port.command(port, <<?k>>)
    {:noreply, state}
  end

  def handle_info({:EXIT, port, _reason}, %State{port: port} = state),
    do: {:stop, :normal, %{state | port: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the port makes the helper see EOF and take the harness with it.
    if is_port(state.port), do: Port.close(state.port)
    state = flush(state)
    Log.close(state.log)
    :ok
  end

  ## Internals

  defp finish(state, code) do
    state = flush(state)

    if retry_without_resume?(state, code),
      do: relaunch(state),
      else: update(state, status: :exited, exit_code: code, completed_at: DateTime.utc_now())
  end

  # Only when the harness itself gave up on the conversation: not when the
  # user pressed Stop, and not when a signal ended it (128 + signal), which
  # means something killed it rather than it refusing to resume.
  defp retry_without_resume?(state, code) do
    state.resumed? and not state.retried? and not state.stopping? and code != 0 and
      code < 128 and
      System.monotonic_time(:millisecond) - (state.started_ms || 0) < @resume_grace_ms
  end

  # The conversation could not be continued. Rather than leaving a terminal
  # that died on arrival, start a fresh one in the same place and say so —
  # the user asked for a terminal, not for an error message.
  defp relaunch(state) do
    case Terminals.fresh_launch(state.terminal) do
      {:ok, launch} ->
        note(state, "could not continue the previous conversation; starting a new one")
        state = %{state | retried?: true, port: nil}
        {:noreply, state} = handle_continue({:spawn, launch}, state)
        state

      _ ->
        update(state, status: :exited, exit_code: 1, completed_at: DateTime.utc_now())
    end
  end

  defp note(state, text) do
    line = "\r\n\e[2m[alkim] " <> text <> "\e[0m\r\n"
    Terminals.broadcast(state.terminal.id, {:terminal_output, state.terminal.id, line})
    Log.write(state.log, line)
  end

  defp update(state, attrs) do
    terminal = struct(state.terminal, Map.new(attrs))
    Terminals.save(terminal)
    Terminals.broadcast_status(terminal.id, {:terminal_status, terminal})
    %{state | terminal: terminal}
  end

  ## Output: coalesced for the wire, bounded for the scrollback

  defp buffer(state, chunk),
    do: %{state | pending: [chunk | state.pending || []]}

  defp schedule_flush(%State{flush_timer: nil} = state),
    do: %{state | flush_timer: Process.send_after(self(), :flush, @flush_ms)}

  defp schedule_flush(state), do: state

  defp flush(%State{pending: nil} = state), do: state
  defp flush(%State{pending: []} = state), do: %{state | pending: nil}

  defp flush(state) do
    data = state.pending |> Enum.reverse() |> IO.iodata_to_binary()
    Terminals.broadcast(state.terminal.id, {:terminal_output, state.terminal.id, data})

    if state.flush_timer, do: Process.cancel_timer(state.flush_timer)
    state |> save(data) |> Map.merge(%{pending: nil, flush_timer: nil})
  end

  defp save(%State{log: nil} = state, _data), do: state

  defp save(state, data) do
    Log.write(state.log, data)
    written = state.log_bytes + byte_size(data)

    if written > Log.max_bytes() do
      scrollback = state.scrollback |> Enum.reverse() |> IO.iodata_to_binary()
      log = Log.rewrite(state.terminal.id, state.log, scrollback)
      %{state | log: log, log_bytes: byte_size(scrollback)}
    else
      %{state | log_bytes: written}
    end
  end

  # Whole chunks are dropped rather than split: cutting an escape sequence in
  # half would corrupt the replay for everything that follows it.
  defp keep(state, chunk) do
    scrollback = [chunk | state.scrollback]

    trim(%{
      state
      | scrollback: scrollback,
        scrollback_bytes: state.scrollback_bytes + byte_size(chunk)
    })
  end

  defp trim(%State{scrollback_bytes: bytes} = state) when bytes <= @scrollback_bytes, do: state

  defp trim(state) do
    {kept, bytes} =
      Enum.reduce_while(state.scrollback, {[], 0}, fn chunk, {acc, bytes} ->
        size = bytes + byte_size(chunk)

        if size > @scrollback_bytes,
          do: {:halt, {acc, bytes}},
          else: {:cont, {[chunk | acc], size}}
      end)

    %{state | scrollback: Enum.reverse(kept), scrollback_bytes: bytes}
  end

  defp env(launch) do
    for {key, value} <- Map.get(launch, :env, []) do
      {String.to_charlist(key), if(value == false, do: false, else: String.to_charlist(value))}
    end
  end

  defp quit_sequence(harness) do
    with {:ok, adapter} <- Alkim.Harness.fetch_adapter(harness),
         true <- function_exported?(adapter, :quit_sequence, 0) do
      adapter.quit_sequence()
    else
      _ -> nil
    end
  end

  defp helper, do: Application.app_dir(:alkim, "priv/bin/alkim-pty")
end
