defmodule Alkim.Runtime.SessionServer do
  @moduledoc """
  One process per session. It owns the harness port, holds the session's
  runtime state and recent activity, persists status transitions and
  publishes every event on `Alkim.Runtime.EventBus`.

  Restart strategy is `:temporary`: restarting would re-run the prompt, and a
  coding agent must never silently repeat work. If this process crashes, the
  port (linked) closes, the wrapper kills the harness, and
  `Alkim.Runtime.CrashMonitor` calls `record_crash/2`. Nothing else in the
  runtime is affected.

  A session may have an *owner* (e.g. a workflow): the owner receives every
  event as a message — no subscription race — and if the owner dies the
  session stops, so a crashed workflow never leaves agents running.

  After a session reaches a terminal status the process stays alive for a
  retention period (`:session_retention_ms`) so its activity log remains
  viewable, then exits normally. The persisted record outlives it.
  """

  use GenServer, restart: :temporary

  alias Alkim.{Session, Sessions}
  alias Alkim.Harness.Capabilities
  alias Alkim.Runtime.{CrashMonitor, Event, EventBus, OSProcess, Registry}

  @max_events 2_000

  defmodule State do
    @moduledoc false
    defstruct [
      :session,
      :adapter,
      :capabilities,
      :executable,
      :port,
      :turn_timer,
      :turn_timeout,
      :retention_timer,
      :retention,
      :owner,
      :owner_ref,
      :provider_profile,
      buffer: [],
      events: [],
      event_count: 0,
      seq: 0,
      stopping?: false
    ]
  end

  ## Client API — normally reached through Alkim.Runtime.

  def start_link(opts) do
    session = Keyword.fetch!(opts, :session)
    GenServer.start_link(__MODULE__, opts, name: Registry.via(session.id, summary(session)))
  end

  @doc "Snapshot of the session and its retained events (oldest first)."
  def snapshot(pid), do: GenServer.call(pid, :snapshot)

  def stop(pid), do: GenServer.call(pid, :stop)
  def complete(pid), do: GenServer.call(pid, :complete)
  def send_message(pid, text), do: GenServer.call(pid, {:send_message, text})

  ## Callbacks

  @impl true
  def init(opts) do
    # Trap exits so `terminate/2` runs on shutdown and can close the port.
    Process.flag(:trap_exit, true)

    session = %{Keyword.fetch!(opts, :session) | pid: self()}
    CrashMonitor.watch(self(), session.id, __MODULE__)
    owner = Keyword.get(opts, :owner)

    state = %State{
      session: session,
      adapter: Keyword.fetch!(opts, :adapter),
      capabilities: Keyword.fetch!(opts, :adapter).capabilities(),
      executable: Keyword.fetch!(opts, :executable),
      turn_timeout: Keyword.get(opts, :turn_timeout, config(:turn_timeout, :infinity)),
      retention: Keyword.get(opts, :retention, config(:session_retention_ms, :timer.minutes(30))),
      owner: owner,
      owner_ref: owner && Process.monitor(owner),
      provider_profile: Keyword.get(opts, :provider_profile)
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state) do
    state = emit(state, :input, %{text: state.session.prompt})
    {:noreply, start_turn(state, state.session.prompt, nil)}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    {:reply, {state.session, Enum.reverse(state.events)}, state}
  end

  def handle_call(:stop, _from, %State{session: %{status: status}} = state)
      when status in [:starting, :running, :waiting] do
    if state.port, do: OSProcess.close(state.port)
    state = %{state | port: nil, stopping?: true}
    {:reply, :ok, finish(state, :stopped, %{})}
  end

  def handle_call(:stop, _from, state), do: {:reply, {:error, :not_running}, state}

  def handle_call(:complete, _from, %State{session: %{status: :waiting}} = state) do
    {:reply, :ok, finish(state, :completed, %{exit_code: state.session.exit_code})}
  end

  def handle_call(:complete, _from, state), do: {:reply, {:error, :not_waiting}, state}

  def handle_call({:send_message, text}, _from, state) do
    cond do
      not Capabilities.send_message?(state.capabilities) ->
        {:reply, {:error, :unsupported}, state}

      state.session.status != :waiting ->
        {:reply, {:error, :not_waiting}, state}

      is_nil(state.session.harness_ref) ->
        {:reply, {:error, :no_conversation_ref}, state}

      true ->
        state = emit(state, :input, %{text: text})
        {:reply, :ok, start_turn(state, text, state.session.harness_ref)}
    end
  end

  @impl true
  def handle_info({port, {:data, payload}}, %State{port: port} = state) do
    case OSProcess.collect(payload, state.buffer) do
      {:partial, buffer} ->
        {:noreply, %{state | buffer: buffer}}

      {:line, stream, line, buffer} ->
        {:noreply, handle_line(%{state | buffer: buffer}, stream, line)}
    end
  end

  def handle_info({port, {:exit_status, code}}, %State{port: port} = state) do
    state = %{state | port: nil} |> flush_buffer() |> cancel_turn_timer()
    {:noreply, turn_finished(state, code)}
  end

  def handle_info(:turn_timeout, %State{port: port} = state) when is_port(port) do
    OSProcess.close(port)
    state = %{state | port: nil, turn_timer: nil}
    error = "timed out after #{state.turn_timeout} ms"
    state = emit(state, :output, %{kind: :error, text: error})
    {:noreply, finish(state, :failed, %{error: error})}
  end

  def handle_info(:retention_expired, state), do: {:stop, :normal, state}

  # The owner (a workflow) is gone: nobody will consume this session.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %State{owner_ref: ref} = state) do
    state = %{state | owner: nil, owner_ref: nil}

    if Session.terminal?(state.session) do
      {:noreply, state}
    else
      if state.port, do: OSProcess.close(state.port)
      state = %{state | port: nil, stopping?: true}
      {:noreply, finish(state, :stopped, %{error: "owner exited"})}
    end
  end

  # The port is linked; after Port.close/1 (or its exit) we get this.
  def handle_info({:EXIT, port, _reason}, state) when is_port(port), do: {:noreply, state}

  # Stale messages from a port we already closed.
  def handle_info({port, _}, state) when is_port(port), do: {:noreply, state}
  def handle_info(:turn_timeout, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if state.port, do: OSProcess.close(state.port)

    # On runtime shutdown record the session as stopped rather than leaving it
    # "running" forever. Crashes are recorded by CrashMonitor instead.
    if shutdown?(reason) and not Session.terminal?(state.session) do
      now = DateTime.utc_now()
      Sessions.sync(%{state.session | status: :stopped, completed_at: now})
    end

    :ok
  end

  @doc false
  # Called by CrashMonitor when a session process died abnormally.
  def record_crash(id, reason) do
    error = "session process crashed: #{inspect(reason, limit: 5)}"

    with %{} = record <- Sessions.get(id),
         session = Sessions.to_session(record),
         false <- Session.terminal?(session) do
      Sessions.sync(%{session | status: :failed, error: error, completed_at: DateTime.utc_now()})
    end

    # `seq: nil` marks an event emitted on the session's behalf.
    EventBus.publish(Event.new(id, nil, :failed, %{error: error}))
  end

  ## Turns

  defp start_turn(state, prompt, resume) do
    session = state.session

    turn = %{
      prompt: prompt,
      workspace: session.workspace,
      executable: state.executable,
      model: session.model,
      permission_mode: session.permission_mode,
      resume: resume
    }

    # The provider's secret is resolved per turn and only ever placed in the
    # harness process environment.
    with {:ok, provider} <- resolve_provider(state.provider_profile),
         turn = Map.put(turn, :provider, provider),
         {:ok, launch} <- state.adapter.build_command(turn),
         {:ok, port} <- OSProcess.open(launch, session.workspace) do
      os_pid = OSProcess.os_pid(port)
      first_turn? = session.turns == 0

      session = %{
        session
        | status: :running,
          os_pid: os_pid,
          turns: session.turns + 1,
          started_at: session.started_at || DateTime.utc_now(),
          exit_code: nil
      }

      state =
        %{state | port: port, buffer: [], session: session} |> start_turn_timer() |> persist()

      if first_turn?,
        do: emit(state, :started, %{os_pid: os_pid}),
        else: emit(state, :resumed, %{os_pid: os_pid, turn: session.turns})
    else
      {:error, reason} ->
        error =
          "could not start harness: #{if is_binary(reason), do: reason, else: inspect(reason)}"

        state |> emit(:output, %{kind: :error, text: error}) |> finish(:failed, %{error: error})
    end
  end

  defp resolve_provider(nil), do: {:ok, nil}
  defp resolve_provider(profile_id), do: Alkim.Providers.resolve(profile_id)

  defp turn_finished(%State{stopping?: true} = state, _code), do: state

  defp turn_finished(state, 0) do
    resumable? =
      Capabilities.send_message?(state.capabilities) and not is_nil(state.session.harness_ref)

    if resumable? do
      session = %{state.session | status: :waiting, exit_code: 0, os_pid: nil}
      %{state | session: session} |> persist() |> emit(:waiting, %{})
    else
      finish(state, :completed, %{exit_code: 0})
    end
  end

  defp turn_finished(state, code) do
    finish(state, :failed, %{exit_code: code, error: "harness exited with status #{code}"})
  end

  defp finish(state, status, attrs) do
    session =
      struct!(state.session, Map.merge(attrs, %{status: status, os_pid: nil}))
      |> Map.put(:completed_at, DateTime.utc_now())

    %{state | session: session}
    |> cancel_turn_timer()
    |> persist()
    |> emit(status, Map.take(attrs, [:exit_code, :error]))
    |> schedule_retention()
  end

  ## Output

  defp handle_line(state, stream, line) do
    stream
    |> state.adapter.parse_output(line)
    |> Enum.reduce(state, &apply_harness_event/2)
  end

  defp apply_harness_event({:harness_ref, ref}, state) do
    if state.session.harness_ref == ref do
      state
    else
      %{state | session: %{state.session | harness_ref: ref}} |> persist()
    end
  end

  defp apply_harness_event({:message, kind, text}, state), do: output(state, kind, text)

  defp apply_harness_event({:tool, name, summary}, state),
    do: output(state, :tool, "#{name} #{summary}")

  defp apply_harness_event({:output, text}, state), do: output(state, :stdout, text)
  defp apply_harness_event({:stderr, text}, state), do: output(state, :stderr, text)
  defp apply_harness_event({:system, text}, state), do: output(state, :system, text)
  defp apply_harness_event({:error, text}, state), do: output(state, :error, text)

  defp apply_harness_event({:result, result}, state) do
    session = %{state.session | metadata: Map.put(state.session.metadata, "last_result", result)}
    output(%{state | session: session}, :result, format_result(result))
  end

  defp output(state, _kind, ""), do: state

  # Harnesses sometimes report the same thing twice in a row (e.g. Codex
  # emits both `error` and `turn.failed` with one message).
  defp output(
         %State{events: [%Event{type: :output, data: %{kind: kind, text: text}} | _]} = state,
         kind,
         text
       ),
       do: state

  defp output(state, kind, text), do: emit(state, :output, %{kind: kind, text: text})

  defp flush_buffer(%State{buffer: []} = state), do: state

  defp flush_buffer(state) do
    {:line, stream, line, []} = OSProcess.collect({:eol, ""}, state.buffer)
    handle_line(%{state | buffer: []}, stream, line)
  end

  defp format_result(result) do
    result
    |> Enum.reject(fn {_k, v} -> is_nil(v) or is_map(v) end)
    |> Enum.map_join("  ", fn {k, v} -> "#{k}=#{v}" end)
    |> case do
      "" -> "turn finished"
      text -> text
    end
  end

  ## Events, persistence, timers

  defp emit(state, type, data) do
    seq = state.seq + 1
    event = Event.new(state.session.id, seq, type, data)
    EventBus.publish(event)
    if state.owner, do: send(state.owner, {:session_event, event})

    {events, count} =
      if state.event_count >= @max_events,
        do: {[event | Enum.take(state.events, @max_events - 1)], @max_events},
        else: {[event | state.events], state.event_count + 1}

    %{state | seq: seq, events: events, event_count: count}
  end

  defp persist(state) do
    Sessions.sync(state.session)
    Registry.put_summary(state.session.id, summary(state.session))
    state
  end

  defp summary(session) do
    Map.take(session, [
      :harness,
      :workspace,
      :project_id,
      :status,
      :started_at,
      :completed_at,
      :prompt,
      :model,
      :metadata
    ])
  end

  defp start_turn_timer(%State{turn_timeout: :infinity} = state), do: state

  defp start_turn_timer(state) do
    %{state | turn_timer: Process.send_after(self(), :turn_timeout, state.turn_timeout)}
  end

  defp cancel_turn_timer(%State{turn_timer: nil} = state), do: state

  defp cancel_turn_timer(state) do
    Process.cancel_timer(state.turn_timer)
    %{state | turn_timer: nil}
  end

  defp schedule_retention(%State{retention: :infinity} = state), do: state

  defp schedule_retention(state) do
    if state.retention_timer, do: Process.cancel_timer(state.retention_timer)
    %{state | retention_timer: Process.send_after(self(), :retention_expired, state.retention)}
  end

  defp shutdown?(:shutdown), do: true
  defp shutdown?({:shutdown, _}), do: true
  defp shutdown?(_), do: false

  defp config(key, default), do: Application.get_env(:alkim, key, default)
end
