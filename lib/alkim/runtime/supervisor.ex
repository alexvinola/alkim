defmodule Alkim.Runtime.Supervisor do
  @moduledoc """
  Root of the runtime:

      Alkim.Runtime.Supervisor (rest_for_one)
      ├── Alkim.Runtime.Registry          session id → pid + summary
      ├── Alkim.Runtime.SessionSupervisor DynamicSupervisor of sessions
      ├── Alkim.Workflow.Registry         workflow id → pid
      ├── Alkim.Workflow.Supervisor       DynamicSupervisor of workflows
      ├── Alkim.Terminals.Registry        terminal id → pid
      ├── Alkim.Terminals.Supervisor      DynamicSupervisor of interactive terminals
      ├── Alkim.Runtime.CrashMonitor      records crashed sessions/workflows
      └── Alkim.Harness.Discovery         installed harnesses (cached)

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
      Alkim.Runtime.Registry,
      Alkim.Runtime.SessionSupervisor,
      {Registry, keys: :unique, name: Alkim.Workflow.Registry},
      Alkim.Workflow.Supervisor,
      Alkim.Terminals.Registry,
      Alkim.Terminals.Supervisor,
      {Alkim.Runtime.CrashMonitor,
       watch: [
         {Alkim.Runtime.Registry, Alkim.Runtime.SessionServer},
         {Alkim.Workflow.Registry, Alkim.Workflow.Server}
       ]},
      Alkim.Harness.Discovery
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
