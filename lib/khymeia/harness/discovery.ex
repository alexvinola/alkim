defmodule Khymeia.Harness.Discovery do
  @moduledoc """
  Detects which harnesses are installed and caches the result.

  Detection shells out (`claude --version`, ...), so it runs once after boot —
  asynchronously, to never delay startup — and again on `refresh/0`. Changes
  are broadcast on the `"harnesses"` topic of `Khymeia.Runtime.EventBus`.

  Results are `t:harness/0` maps:

      %{id: :claude, name: "Claude Code", status: :available,
        executable: "/opt/homebrew/bin/claude", version: "2.1.0 (Claude Code)",
        adapter: Khymeia.Harness.Claude, capabilities: %Capabilities{},
        models: [%{id: "opus", name: "opus", description: "..."}]}

  `models` are the ones the installed CLI reports (see
  `c:Khymeia.Harness.list_models/1`), or the adapter's fixed list; `[]` when
  neither is available.

  `status` is `:available` (installed and integrated), `:not_installed`, or
  `:no_adapter` (installed, but Khymeia has no integration yet).
  """

  use GenServer

  alias Khymeia.Harness
  alias Khymeia.Harness.Executable
  alias Khymeia.Runtime.EventBus

  @type harness :: %{
          id: atom(),
          name: String.t(),
          status: :available | :not_installed | :no_adapter,
          executable: String.t() | nil,
          version: String.t() | nil,
          adapter: module() | nil,
          capabilities: Khymeia.Harness.Capabilities.t() | nil,
          models: [Khymeia.Harness.model()]
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Cached detection results. Empty until the first scan finishes."
  @spec list() :: [harness()]
  def list, do: GenServer.call(__MODULE__, :list, 20_000)

  @doc "Returns the cached entry for an available harness."
  @spec fetch_available(atom()) :: {:ok, harness()} | {:error, :not_installed | :unknown_harness}
  def fetch_available(id) do
    case Enum.find(list(), &(&1.id == id)) do
      %{status: :available} = harness -> {:ok, harness}
      nil -> {:error, :unknown_harness}
      _ -> {:error, :not_installed}
    end
  end

  @doc "Re-runs detection synchronously and returns the new results."
  @spec refresh() :: [harness()]
  def refresh, do: GenServer.call(__MODULE__, :refresh, 30_000)

  @doc "Runs detection without touching the cache. Pure apart from the probes."
  @spec scan([module()], [map()]) :: [harness()]
  def scan(adapters \\ Harness.adapters(), planned \\ Harness.planned()) do
    integrated =
      adapters
      |> Task.async_stream(&detect_adapter/1, timeout: 15_000, on_timeout: :kill_task)
      |> Enum.zip(adapters)
      |> Enum.map(fn
        {{:ok, harness}, _adapter} -> harness
        {{:exit, _}, adapter} -> not_installed(adapter)
      end)

    known = MapSet.new(integrated, & &1.id)

    others =
      for entry <- planned, entry.id not in known do
        case Executable.find(entry.id, entry.executable) do
          {:ok, path} -> base(entry.id, entry.name, :no_adapter, path)
          :not_found -> base(entry.id, entry.name, :not_installed, nil)
        end
      end

    integrated ++ others
  end

  @impl true
  def init(_opts), do: {:ok, [], {:continue, :scan}}

  @impl true
  def handle_continue(:scan, _state), do: {:noreply, rescan([])}

  @impl true
  def handle_call(:list, _from, harnesses), do: {:reply, harnesses, harnesses}

  def handle_call(:refresh, _from, harnesses) do
    harnesses = rescan(harnesses)
    {:reply, harnesses, harnesses}
  end

  defp rescan(previous) do
    harnesses = scan()
    if harnesses != previous, do: EventBus.broadcast_harnesses(harnesses)
    harnesses
  end

  defp detect_adapter(adapter) do
    case adapter.detect() do
      {:ok, detection} ->
        %{
          base(adapter.id(), adapter.name(), :available, detection.executable)
          | version: Map.get(detection, :version),
            adapter: adapter,
            capabilities: adapter.capabilities(),
            models: models(adapter, detection.executable)
        }

      :not_found ->
        not_installed(adapter)
    end
  end

  defp models(adapter, executable) do
    reported =
      if function_exported?(adapter, :list_models, 1),
        do: adapter.list_models(executable),
        else: :error

    case {reported, adapter.capabilities().models} do
      {{:ok, models}, _} ->
        models

      {:error, fixed} when is_list(fixed) ->
        Enum.map(fixed, &%{id: &1, name: &1, description: nil})

      {:error, :unknown} ->
        []
    end
  end

  defp not_installed(adapter),
    do: %{base(adapter.id(), adapter.name(), :not_installed, nil) | adapter: adapter}

  defp base(id, name, status, executable) do
    %{
      id: id,
      name: name,
      status: status,
      executable: executable,
      version: nil,
      adapter: nil,
      capabilities: nil,
      models: []
    }
  end
end
