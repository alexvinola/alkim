defmodule Khymeia.Worktrees do
  @moduledoc """
  Isolated checkouts of a project, one per piece of work.

  Two agents in the same repository is the sharpest edge Khymeia has: they
  share a working tree, overwrite each other's edits, and an auditor cannot
  tell whose change is whose. A git worktree fixes that at the root — each
  gets its own directory and its own branch, off the same base commit.

  What Khymeia does: create them, tell you what changed in them, and remove
  them when you say so.

  What Khymeia never does: **merge**. Nothing here writes to your main
  branch. *Keep* removes the directory and leaves the branch for you to
  review, rebase or merge yourself; *discard* removes both. That line is
  deliberate: a tool that quietly integrates agent work is a tool you cannot
  trust with a repository.
  """

  import Ecto.Query

  alias Khymeia.{Git, Repo, Workspace}
  alias Khymeia.Worktrees.Worktree

  @pubsub Khymeia.PubSub
  @topic "worktrees"

  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @type error :: {:invalid, %{atom() => String.t()}}

  @doc """
  Creates a worktree for `project`, branching from its current `HEAD`.

  `name` is a label the branch and directory are derived from; anything the
  user typed is reduced to a safe slug first, because it ends up as a path
  and a ref.
  """
  @spec create(map(), String.t() | nil) :: {:ok, Worktree.t()} | {:error, error()}
  def create(project, name \\ nil) do
    with {:ok, repository} <- repository(project.path),
         {:ok, base} <- base_commit(repository),
         slug = slug(name),
         {:ok, path} <- destination(repository, slug),
         branch = branch_name(slug),
         :ok <- ensure_free(path, branch) do
      case Git.add_worktree(repository, path, branch, base) do
        {:ok, created} ->
          %Worktree{
            id: Ecto.UUID.generate(),
            project_id: project.id,
            repository: repository,
            path: created.path,
            branch: created.branch,
            base_branch: current_branch(repository),
            base_commit: created.base_commit || base,
            status: :active
          }
          |> insert()

        {:error, message} ->
          {:error, {:invalid, %{worktree: first_line(message)}}}
      end
    end
  end

  @doc """
  Whether a fresh worktree could be created for `workspace`, and if not, why.

  Asked before offering the choice: a form that defaults to isolation and
  then fails on submit is worse than one that says up front that this
  project cannot have it.
  """
  @spec offer(String.t() | nil) :: :ok | {:unavailable, String.t()}
  def offer(nil), do: {:unavailable, "choose a workspace first"}

  def offer(workspace) do
    with {:ok, repository} <- repository(workspace),
         {:ok, _base} <- base_commit(repository),
         {:ok, _path} <- destination(repository, "probe") do
      :ok
    else
      {:error, {:invalid, %{worktree: message}}} -> {:unavailable, message}
    end
  end

  @doc """
  Resolves the `worktree` choice that sessions, workflows and terminals all
  accept:

    * `nil` or `""` — run in the project's own folder;
    * `"new"` — a fresh worktree, named after the work;
    * an id — that worktree, if it is still active.

  Returning `{:ok, nil}` means "no worktree", which is a valid answer and not
  an error: isolation is offered, never imposed.
  """
  @spec claim(String.t() | nil, map() | nil, String.t() | nil) ::
          {:ok, Worktree.t() | nil} | {:error, error()}
  def claim(choice, project, name \\ nil)

  def claim(choice, _project, _name) when choice in [nil, ""], do: {:ok, nil}

  def claim("new", nil, _name),
    do: {:error, {:invalid, %{worktree: "a worktree needs a project"}}}

  def claim("new", project, name), do: create(project, name)

  def claim(id, _project, _name) do
    case get(id) do
      %Worktree{status: :active} = worktree -> {:ok, worktree}
      %Worktree{} -> {:error, {:invalid, %{worktree: "that worktree has been released"}}}
      nil -> {:error, {:invalid, %{worktree: "unknown worktree"}}}
    end
  end

  @doc """
  Removes the directory and leaves the branch: the work stays in git, ready
  for you to review and merge yourself.
  """
  @spec keep(String.t()) :: {:ok, Worktree.t()} | {:error, error()}
  def keep(id), do: release(id, :kept, delete_branch?: false)

  @doc "Removes the directory *and* the branch. The work is gone."
  @spec discard(String.t()) :: {:ok, Worktree.t()} | {:error, error()}
  def discard(id), do: release(id, :discarded, delete_branch?: true)

  defp release(id, status, opts) do
    case get(id) do
      nil ->
        {:error, {:invalid, %{worktree: "that worktree no longer exists"}}}

      %Worktree{status: :active} = worktree ->
        # Force: an agent leaves uncommitted files behind, and git refuses to
        # remove a dirty worktree. The user asked for this explicitly.
        case Git.remove_worktree(worktree.repository, worktree.path, force: true) do
          :ok ->
            if opts[:delete_branch?] do
              Git.delete_branch(worktree.repository, worktree.branch, force: true)
            end

            worktree
            |> Ecto.Changeset.change(status: status, released_at: DateTime.utc_now())
            |> Repo.update()
            |> announce()

          {:error, message} ->
            {:error, {:invalid, %{worktree: first_line(message)}}}
        end

      worktree ->
        {:ok, worktree}
    end
  end

  @doc "What an agent has done in a worktree, compared with where it started."
  @spec work(Worktree.t()) :: Git.work() | :unavailable
  def work(%Worktree{status: :active, base_commit: base} = worktree) when is_binary(base),
    do: Git.work_done(worktree.path, base)

  def work(_worktree), do: :unavailable

  ## Reading

  def get(id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} -> Repo.get(Worktree, uuid)
      :error -> nil
    end
  end

  @doc "Worktrees of a project, active ones first."
  def list_for_project(project_id, limit \\ 20) do
    Worktree
    |> where(project_id: ^project_id)
    |> order_by(desc: :inserted_at)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.sort_by(&(not Worktree.active?(&1)))
  end

  def active_for_project(project_id) do
    project_id |> list_for_project(50) |> Enum.filter(&Worktree.active?/1)
  end

  ## Naming
  #
  # Branch and directory both come from the same slug, so a worktree is
  # recognisable on disk, in `git branch`, and in the UI.

  @prefix "khymeia"

  defp slug(name) do
    base =
      name
      |> to_string()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")
      |> String.slice(0, 32)

    suffix = 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
    if base == "", do: suffix, else: "#{base}-#{suffix}"
  end

  defp branch_name(slug), do: "#{@prefix}/#{slug}"

  # Beside the repository, the way `git worktree` expects: inside the main
  # working tree it would show up as untracked files in every status.
  defp destination(repository, slug) do
    path =
      Path.join(Path.dirname(repository), "#{Path.basename(repository)}-#{@prefix}-#{slug}")

    case Workspace.validate(Path.dirname(path)) do
      {:ok, _} ->
        {:ok, path}

      {:error, _reason} ->
        {:error,
         {:invalid,
          %{
            worktree:
              "worktrees are created beside the repository, and #{Path.dirname(path)} is not inside the allowed workspace roots"
          }}}
    end
  end

  defp ensure_free(path, branch) do
    cond do
      File.exists?(path) -> {:error, {:invalid, %{worktree: "#{path} already exists"}}}
      Repo.get_by(Worktree, branch: branch) -> {:error, {:invalid, %{worktree: "name in use"}}}
      true -> :ok
    end
  end

  ## Helpers

  defp repository(path) do
    case Git.repository(path) do
      :unavailable ->
        {:error, {:invalid, %{worktree: "this project is not a git repository"}}}

      repository ->
        {:ok, repository}
    end
  end

  defp base_commit(repository) do
    case Git.head(repository) do
      nil -> {:error, {:invalid, %{worktree: "this repository has no commits yet"}}}
      sha -> {:ok, sha}
    end
  end

  defp current_branch(repository) do
    case Git.status(repository) do
      %{branch: branch} -> branch
      _ -> nil
    end
  end

  defp insert(worktree) do
    worktree |> Worktree.changeset() |> Repo.insert() |> announce()
  end

  defp announce({:ok, _worktree} = result) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, :worktrees_changed)
    result
  end

  defp announce({:error, %Ecto.Changeset{}}),
    do: {:error, {:invalid, %{worktree: "could not be recorded"}}}

  defp announce(other), do: other

  defp first_line(message), do: message |> String.split("\n", trim: true) |> List.last(message)
end
