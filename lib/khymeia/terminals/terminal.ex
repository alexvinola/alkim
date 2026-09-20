defmodule Khymeia.Terminals.Terminal do
  @moduledoc """
  One interactive harness session: the real CLI, on a real pseudo-terminal,
  inside a workspace.

  A terminal is not a session (`Khymeia.Session`). A session is driven
  headlessly and produces structured events Khymeia can reason about; a
  terminal produces bytes a human reads. They meet at `harness_ref`: the
  harness's own conversation id, which lets the same conversation be
  continued in either lane.

  Status:

      starting ──► running ──► exited
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:starting, :running, :exited]

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "terminals" do
    field :project_id, :binary_id
    field :worktree_id, :binary_id
    field :workspace, :string
    field :harness, :string
    field :provider_profile_id, :binary_id
    field :model, :string
    field :permission_mode, :string
    field :harness_ref, :string
    field :status, Ecto.Enum, values: @statuses, default: :starting
    field :exit_code, :integer
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec

    timestamps()
  end

  def statuses, do: @statuses
  def live?(%__MODULE__{status: status}), do: status != :exited

  @fields ~w(id project_id worktree_id workspace harness provider_profile_id model
             permission_mode harness_ref status exit_code started_at completed_at)a

  def changeset(terminal, attrs \\ %{}) do
    terminal
    |> cast(attrs, @fields)
    |> validate_required([:id, :workspace, :harness, :status])
  end
end
