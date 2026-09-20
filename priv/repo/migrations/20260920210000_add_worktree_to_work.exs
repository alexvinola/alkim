defmodule Alkim.Repo.Migrations.AddWorktreeToWork do
  use Ecto.Migration

  def up do
    alter table(:sessions), do: add(:worktree_id, :binary_id)
    alter table(:workflows), do: add(:worktree_id, :binary_id)

    create index(:sessions, [:worktree_id])
    create index(:workflows, [:worktree_id])
  end

  def down do
    drop index(:sessions, [:worktree_id])
    drop index(:workflows, [:worktree_id])

    alter table(:sessions), do: remove(:worktree_id)
    alter table(:workflows), do: remove(:worktree_id)
  end
end
