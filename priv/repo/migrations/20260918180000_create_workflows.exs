defmodule Khymeia.Repo.Migrations.CreateWorkflows do
  use Ecto.Migration

  def change do
    create table(:workflows, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :title, :string
      add :workspace, :string, null: false
      add :task, :text, null: false
      add :constraints, :text
      add :status, :string, null: false
      add :waiting_reason, :string
      add :waiting_detail, :text
      add :current_step, :string
      add :iteration, :integer, null: false, default: 0
      add :max_iterations, :integer, null: false
      add :definition, :map, null: false
      add :roles, :map, null: false
      add :advisor_calls, :integer, null: false, default: 0
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflows, [:status])
    create index(:workflows, [:inserted_at])

    create table(:workflow_steps, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :workflow_id, references(:workflows, type: :binary_id, on_delete: :delete_all),
        null: false

      add :parent_id, :binary_id
      add :step, :string, null: false
      add :kind, :string, null: false
      add :role, :string
      add :iteration, :integer, null: false
      add :status, :string, null: false
      add :session_id, :binary_id
      add :harness, :string
      add :model, :string
      add :permission_mode, :string
      add :input, :text
      add :summary, :text
      add :changed_files, {:array, :string}
      add :audit, :map
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:workflow_steps, [:workflow_id])
  end
end
