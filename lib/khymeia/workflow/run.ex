defmodule Khymeia.Workflow.Run do
  @moduledoc """
  One execution of a workflow definition — both the state the workflow
  process holds and what is persisted, so the visible state can be rebuilt
  after a restart.

  Status:

      pending → running ⇄ auditing ⇄ fixing → completed
                  │          │          │
                  └──────────┴──────────┴──► waiting  (human checkpoint)
                                              failed   (crash / cannot run)
                                              stopped  (user)

  `waiting` always carries a `waiting_reason`:
  `max_iterations_reached`, `clarification_requested`, `step_failed`,
  `unparseable_audit` or `findings_unresolved`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :waiting, :auditing, :fixing, :completed, :failed, :stopped]
  @terminal [:completed, :failed, :stopped]

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "workflows" do
    field :name, :string
    field :title, :string
    field :workspace, :string
    field :project_id, :binary_id
    field :task, :string
    field :constraints, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :waiting_reason, :string
    field :waiting_detail, :string
    field :current_step, :string
    field :iteration, :integer, default: 0
    field :max_iterations, :integer
    field :definition, :map
    field :roles, :map
    field :advisor_calls, :integer, default: 0
    field :error, :string
    field :metadata, :map, default: %{}
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  def statuses, do: @statuses
  def terminal?(%__MODULE__{status: status}), do: status in @terminal
  def terminal?(status) when is_atom(status), do: status in @terminal
  def active?(run), do: not terminal?(run)

  @fields ~w(id name title workspace project_id task constraints status waiting_reason waiting_detail
             current_step iteration max_iterations definition roles advisor_calls error metadata
             started_at completed_at)a

  def changeset(run, attrs \\ %{}) do
    run
    |> cast(attrs, @fields)
    |> validate_required([
      :id,
      :name,
      :workspace,
      :task,
      :status,
      :max_iterations,
      :definition,
      :roles
    ])
  end
end
