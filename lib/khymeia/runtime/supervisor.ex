defmodule Khymeia.Runtime.Supervisor do
  @moduledoc """
  Root of the runtime:

      Khymeia.Runtime.Supervisor (rest_for_one)
      ├── Khymeia.Runtime.Registry          session id → pid + summary
      ├── Khymeia.Runtime.SessionSupervisor DynamicSupervisor of sessions
      ├── Khymeia.Workflow.Registry         workflow id → pid
      ├── Khymeia.Workflow.Supervisor       DynamicSupervisor of workflows
      ├── Khymeia.Terminals.Registry        terminal id → pid
      ├── Khymeia.Terminals.Supervisor      DynamicSupervisor of interactive terminals
      ├── Khymeia.Runtime.CrashMonitor      records crashed sessions/workflows
      └── Khymeia.Harness.Discovery         installed harnesses (cached)

  Order matters with `rest_for_one`: a child's crash restarts it and every
  child after it.

    * Registry dies → sessions registered in it are unreachable, so they are
      restarted (i.e. terminated; they are `:temporary`) together with it.
    * SessionSupervisor dies → workflows (which drive sessions) restart too.
    * A workflow never takes others down: workflows are `:temporary`
      children of their own DynamicSupervisor.
    * CrashMonitor dies → it (and Discovery) restart; it re-watches every
      session and workflow found in the registries. Live ones are untouched.
    * Discovery dies → it restarts alone.
  """

  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      Khymeia.Runtime.Registry,
      Khymeia.Runtime.SessionSupervisor,
      {Registry, keys: :unique, name: Khymeia.Workflow.Registry},
      Khymeia.Workflow.Supervisor,
      Khymeia.Terminals.Registry,
      Khymeia.Terminals.Supervisor,
      {Khymeia.Runtime.CrashMonitor,
       watch: [
         {Khymeia.Runtime.Registry, Khymeia.Runtime.SessionServer},
         {Khymeia.Workflow.Registry, Khymeia.Workflow.Server}
       ]},
      Khymeia.Harness.Discovery
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
