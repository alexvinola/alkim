defmodule Alkim.Workflow.Supervisor do
  @moduledoc """
  `DynamicSupervisor` holding one `Alkim.Workflow.Server` per active run.

  Children are `:temporary`: a crashed workflow is recorded (by
  `Alkim.Runtime.CrashMonitor`) rather than restarted, and it cannot
  affect other workflows or exhaust this supervisor's restart intensity.
  The agents a workflow drives live under `Alkim.Runtime.SessionSupervisor`
  and stop by themselves when their owning workflow disappears.
  """

  use DynamicSupervisor

  def start_link(opts), do: DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def start_workflow(opts),
    do: DynamicSupervisor.start_child(__MODULE__, {Alkim.Workflow.Server, opts})

  def children, do: DynamicSupervisor.which_children(__MODULE__)

  @impl true
  def init(_opts) do
    max = Application.get_env(:alkim, :max_workflows, :infinity)
    DynamicSupervisor.init(strategy: :one_for_one, max_children: max)
  end
end
