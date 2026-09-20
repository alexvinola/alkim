defmodule Alkim.Repo.Migrations.CreateTerminals do
  use Ecto.Migration

  def change do
    create table(:terminals, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :project_id, :binary_id
      add :workspace, :string, null: false
      add :harness, :string, null: false
      add :provider_profile_id, :binary_id
      add :model, :string
      add :permission_mode, :string
      # The harness's own conversation id, when the CLI lets Alkim pick or
      # report one. Never a credential.
      add :harness_ref, :string
      add :status, :string, null: false
      add :exit_code, :integer
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:terminals, [:project_id])
    create index(:terminals, [:status])
  end
end
