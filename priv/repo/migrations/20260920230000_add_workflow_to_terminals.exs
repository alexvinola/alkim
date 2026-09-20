defmodule Alkim.Repo.Migrations.AddWorkflowToTerminals do
  use Ecto.Migration

  def change do
    alter table(:terminals) do
      # A terminal opened on a workflow's agent belongs to that run, and to
      # the role whose conversation it continues. That is what lets a run
      # show its own terminals instead of scattering them in the project.
      add :workflow_id, :binary_id
      add :role, :string
    end

    create index(:terminals, [:workflow_id])
  end
end
