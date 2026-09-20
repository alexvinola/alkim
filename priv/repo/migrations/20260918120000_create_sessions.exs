defmodule Alkim.Repo.Migrations.CreateSessions do
  use Ecto.Migration

  def change do
    create table(:sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :harness, :string, null: false
      add :workspace, :string, null: false
      add :prompt, :text, null: false
      add :model, :string
      add :permission_mode, :string
      add :status, :string, null: false
      add :harness_ref, :string
      add :turns, :integer, null: false, default: 0
      add :exit_code, :integer
      add :error, :text
      add :metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime_usec
      add :completed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create index(:sessions, [:status])
    create index(:sessions, [:inserted_at])
  end
end
