defmodule Khymeia.Worktrees.Worktree do
  @moduledoc """
  One isolated checkout of a project: its own directory and its own branch,
  so an agent can work without touching the files anyone else is using.

  Status says what became of it:

      active ──► kept       the directory is gone, the branch remains
             └─► discarded  both are gone

  Khymeia never merges a worktree's branch. Deciding what reaches the main
  branch is the developer's call, so "keep" means *keep the branch around*,
  not *integrate it*.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:active, :kept, :discarded]

  @primary_key {:id, :binary_id, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "worktrees" do
    field :project_id, :binary_id
    field :repository, :string
    field :path, :string
    field :branch, :string
    field :base_branch, :string
    field :base_commit, :string
    field :status, Ecto.Enum, values: @statuses, default: :active
    field :released_at, :utc_datetime_usec

    timestamps()
  end

  def statuses, do: @statuses
  def active?(%__MODULE__{status: status}), do: status == :active

  @fields ~w(id project_id repository path branch base_branch base_commit status released_at)a

  def changeset(worktree, attrs \\ %{}) do
    worktree
    |> cast(attrs, @fields)
    |> validate_required([:id, :repository, :path, :branch, :status])
    |> unique_constraint(:path)
  end
end
