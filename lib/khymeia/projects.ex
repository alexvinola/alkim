defmodule Khymeia.Projects do
  @moduledoc """
  Projects: the directories the user works in.

  Sessions and workflows always belong to one, so the UI can group work by
  place. A project is created explicitly, or implicitly the first time a
  workspace is used — `ensure_for_workspace/1` reuses the innermost project
  that already contains the path, which keeps subdirectories (and, later,
  worktrees) attached to the project they came from.
  """

  import Ecto.Query

  alias Khymeia.Projects.Project
  alias Khymeia.Repo
  alias Khymeia.Sessions.SessionRecord
  alias Khymeia.Workflow.Run

  @doc "Every project, most recently opened first."
  @spec list() :: [Project.t()]
  def list do
    Project
    |> order_by([p], desc_nulls_last: p.last_opened_at, asc: p.name)
    |> Repo.all()
  end

  @spec get(String.t() | nil) :: Project.t() | nil
  def get(nil), do: nil

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Project, uuid)
      :error -> nil
    end
  end

  @spec get_by_path(String.t()) :: Project.t() | nil
  def get_by_path(path), do: Repo.get_by(Project, path: path)

  @doc """
  Creates a project. `attrs` carries a `"path"` and an optional `"name"`,
  which defaults to the directory's basename.
  """
  @spec create(map()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Project{id: Ecto.UUID.generate(), last_opened_at: DateTime.utc_now()}
    |> Project.changeset(attrs)
    |> Repo.insert()
    |> announce()
  end

  @spec rename(Project.t(), String.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def rename(%Project{} = project, name) do
    project |> Project.changeset(%{"name" => name}) |> Repo.update() |> announce()
  end

  @doc """
  Removes a project. Its sessions and workflows are kept — only their link
  is cleared, because history must never disappear behind a UI action.
  """
  @spec delete(Project.t()) :: {:ok, Project.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Project{} = project) do
    Repo.update_all(where(SessionRecord, project_id: ^project.id), set: [project_id: nil])
    Repo.update_all(where(Run, project_id: ^project.id), set: [project_id: nil])
    project |> Repo.delete() |> announce()
  end

  @doc "Marks a project as just used, for ordering."
  def touch(%Project{} = project) do
    project
    |> Ecto.Changeset.change(last_opened_at: DateTime.utc_now())
    |> Repo.update()
    |> announce()
  end

  def touch(_), do: :ok

  @doc """
  The project a workspace belongs to, creating one if no existing project
  contains it. Returns `nil` only when the path cannot become a project.
  """
  @spec ensure_for_workspace(String.t()) :: Project.t() | nil
  def ensure_for_workspace(path) when is_binary(path) do
    case for_workspace(path) do
      %Project{} = project ->
        project

      nil ->
        case create(%{"path" => path}) do
          {:ok, project} -> project
          # A concurrent insert won the unique index — reuse the winner.
          {:error, _} -> get_by_path(path)
        end
    end
  end

  def ensure_for_workspace(_), do: nil

  @doc "The innermost existing project containing `path` (or exactly at it)."
  @spec for_workspace(String.t()) :: Project.t() | nil
  def for_workspace(path) when is_binary(path) do
    Project
    |> Repo.all()
    |> Enum.filter(&contains?(&1, path))
    |> Enum.max_by(&String.length(&1.path), fn -> nil end)
  end

  def for_workspace(_), do: nil

  defp contains?(%Project{path: root}, path),
    do: path == root or String.starts_with?(path, root <> "/")

  @doc """
  `%{project_id => count}` of sessions and workflows that are still active,
  read from the live registry and the workflow supervisor — never from disk.
  """
  @spec active_counts() :: %{optional(String.t()) => non_neg_integer()}
  def active_counts do
    sessions =
      Khymeia.Runtime.list_live()
      |> Enum.reject(&Khymeia.Session.terminal?(&1.status))
      |> Enum.map(& &1[:project_id])

    workflows =
      Khymeia.Workflow.list_recent(50)
      |> Enum.filter(&Khymeia.Workflow.Run.active?/1)
      |> Enum.map(& &1.project_id)

    terminals =
      Khymeia.Terminals.list_recent(50)
      |> Enum.filter(&Khymeia.Terminals.Terminal.live?/1)
      |> Enum.filter(&Khymeia.Terminals.alive?(&1.id))
      |> Enum.map(& &1.project_id)

    (sessions ++ workflows ++ terminals)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  defp announce({:ok, _project} = result) do
    Khymeia.Runtime.EventBus.broadcast_nav()
    result
  end

  defp announce(other), do: other
end
