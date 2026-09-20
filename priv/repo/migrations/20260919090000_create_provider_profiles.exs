defmodule Alkim.Repo.Migrations.CreateProviderProfiles do
  use Ecto.Migration

  def change do
    create table(:provider_profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :harness, :string, null: false
      add :kind, :string, null: false
      add :settings, :map, null: false, default: %{}
      add :default_model, :string
      # How to obtain the credential — never the credential itself.
      add :credential, :string, null: false, default: "ambient"
      add :credential_env, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:provider_profiles, [:name])
  end
end
