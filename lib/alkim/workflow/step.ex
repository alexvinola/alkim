defmodule Alkim.Workflow.Step do
  @moduledoc """
  A persisted step of a run: one role executing once, an advisor
  consultation (`kind: :advisor`, child of the step that asked) or a human
  interaction (`kind: :human`). The workflow detail view and its timeline
  are projections of these records, so they survive restarts.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Alkim.Workflow.{AuditResult, StepResult}

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflow_steps" do
    field :workflow_id, :binary_id
    field :parent_id, :binary_id
    field :step, :string
    field :kind, Ecto.Enum, values: [:step, :advisor, :human]
    field :role, :string
    field :iteration, :integer
    field :status, Ecto.Enum, values: [:running, :waiting, :completed, :failed, :stopped]
    field :session_id, :binary_id
    field :harness, :string
    field :model, :string
    field :permission_mode, :string
    field :input, :string
    field :summary, :string
    field :changed_files, {:array, :string}
    field :audit, :map
    field :error, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  @fields ~w(id workflow_id parent_id step kind role iteration status session_id harness model
             permission_mode input summary changed_files audit error metadata started_at completed_at)a

  def changeset(step, attrs \\ %{}), do: cast(step, attrs, @fields)

  def audit_result(%__MODULE__{audit: audit}), do: AuditResult.from_map(audit)

  def step_result(%__MODULE__{} = s) do
    %StepResult{
      status: if(s.status == :failed, do: :failed, else: :completed),
      summary: s.summary || "",
      changed_files: s.changed_files,
      metadata: s.metadata
    }
  end
end
