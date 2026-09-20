defmodule Alkim.Repo.Migrations.CreateWorktrees do
  use Ecto.Migration

  def change do
    create table(:worktrees, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, :binary_id
      add :repository, :string, null: false
      add :path, :string, null: false
      add :branch, :string, null: false
      add :base_branch, :string
      add :base_commit, :string
      add :status, :string, null: false
      add :released_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:worktrees, [:path])
    create index(:worktrees, [:project_id])

    # A terminal can run inside an isolated worktree instead of the project.
    alter table(:terminals), do: add(:worktree_id, :binary_id)
    create index(:terminals, [:worktree_id])
  end
end
