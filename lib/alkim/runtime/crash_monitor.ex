defmodule Alkim.Runtime.CrashMonitor do
  @moduledoc """
  Records supervised processes (sessions, workflows) that die abnormally.

  A process that crashes cannot report its own death (`terminate/2` is not
  guaranteed to run, e.g. on `:kill`). This process monitors each one and,
  on an abnormal exit, calls `recorder.record_crash(id, reason)` so the
  persisted state and the UI reflect reality.

  Normal exits and shutdowns are ignored: the process already persisted its
  final state itself.

  Started with `watch: [{registry, recorder}]`: after a restart it re-watches
  every process found in those registries.
  """

  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Starts monitoring `pid`, known as `id`, whose crashes `recorder` records."
  def watch(pid, id, recorder), do: GenServer.cast(__MODULE__, {:watch, pid, id, recorder})

  @impl true
  def init(opts) do
    # After a restart, pick up every process that is already running. Our
    # name is registered before init/1 runs, so nothing can slip between
    # this scan and the casts we will receive.
    watched =
      for {registry, recorder} <- Keyword.get(opts, :watch, []),
          {id, pid} <- Registry.select(registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}]),
          reduce: %{} do
        acc -> monitor(acc, pid, id, recorder)
      end

    {:ok, watched}
  end

  @impl true
  def handle_cast({:watch, pid, id, recorder}, watched),
    do: {:noreply, monitor(watched, pid, id, recorder)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, watched) do
    {entry, watched} = Map.pop(watched, pid)

    with {id, recorder} <- entry, true <- abnormal?(reason) do
      Logger.error("#{inspect(recorder)} #{id} crashed: #{inspect(reason)}")

      try do
        recorder.record_crash(id, reason)
      rescue
        error -> Logger.error("could not record crash of #{id}: #{inspect(error)}")
      end
    end

    {:noreply, watched}
  end

  defp monitor(watched, pid, id, recorder) do
    if Map.has_key?(watched, pid) do
      watched
    else
      Process.monitor(pid)
      Map.put(watched, pid, {id, recorder})
    end
  end

  defp abnormal?(:normal), do: false
  defp abnormal?(:shutdown), do: false
  defp abnormal?({:shutdown, _}), do: false
  defp abnormal?(_), do: true
end
