defmodule Alkim.Workflow.Event do
  @moduledoc """
  Something that happened in a workflow. Names:

      workflow.started  workflow.completed  workflow.failed  workflow.waiting
      workflow.stopped  workflow.resumed
      workflow.iteration.started  workflow.iteration.completed
      workflow.step.started  workflow.step.completed  workflow.step.failed
      advisor.started  advisor.completed  advisor.failed
      audit.started  audit.completed  audit.findings
      human.requested  human.answered

  Published through `Alkim.Runtime.EventBus` on `"workflow:<id>"` and
  `"workflows"`. The persisted run and steps are the source of truth; events
  tell subscribers *when* to look.
  """

  @enforce_keys [:workflow_id, :name, :at]
  defstruct [:workflow_id, :name, :at, data: %{}]

  @type t :: %__MODULE__{workflow_id: String.t(), name: String.t(), at: DateTime.t(), data: map()}

  def new(workflow_id, name, data \\ %{}),
    do: %__MODULE__{workflow_id: workflow_id, name: name, at: DateTime.utc_now(), data: data}
end
