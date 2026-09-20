defmodule Khymeia.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def up do
    create table(:projects, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :path, :string, null: false
      add :last_opened_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:projects, [:path])

    alter table(:sessions), do: add(:project_id, :binary_id)
    alter table(:workflows), do: add(:project_id, :binary_id)

    create index(:sessions, [:project_id])
    create index(:workflows, [:project_id])

    flush()
    backfill()
  end

  def down do
    # SQLite refuses to drop a column an index still depends on.
    drop index(:sessions, [:project_id])
    drop index(:workflows, [:project_id])

    alter table(:sessions), do: remove(:project_id)
    alter table(:workflows), do: remove(:project_id)
    drop table(:projects)
  end

  # Every workspace already used becomes a project, so existing history keeps
  # its place in the new UI instead of showing up as orphaned.
  defp backfill do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    workspaces =
      query("select distinct workspace from sessions") ++
        query("select distinct workspace from workflows")

    workspaces
    |> Enum.uniq()
    |> Enum.each(fn path ->
      id = Ecto.UUID.generate()

      repo().query!(
        "insert into projects (id, name, path, last_opened_at, inserted_at, updated_at) values (?, ?, ?, ?, ?, ?)",
        [id, Path.basename(path), path, now, now, now]
      )

      repo().query!("update sessions set project_id = ? where workspace = ?", [id, path])
      repo().query!("update workflows set project_id = ? where workspace = ?", [id, path])
    end)
  end

  defp query(sql), do: repo().query!(sql).rows |> Enum.map(&hd/1)
end
