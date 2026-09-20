defmodule Khymeia.WorktreesTest do
  use Khymeia.RuntimeCase, async: false

  import Khymeia.RuntimeCase, only: [git_workspace!: 0, workspace!: 0, eventually: 1]

  alias Khymeia.{Projects, Terminals, Worktrees}

  setup do
    path = git_workspace!()
    {:ok, project} = Projects.create(%{"path" => path})
    {:ok, project: project}
  end

  test "a worktree is its own directory on its own branch", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "add search")

    assert File.dir?(worktree.path)
    assert worktree.branch =~ ~r"^khymeia/add-search-"
    assert worktree.base_branch == "main"
    assert worktree.repository == project.path
    # Beside the repository, not inside it: otherwise every git status in the
    # project would report the worktree as untracked files.
    refute String.starts_with?(worktree.path, project.path <> "/")
  end

  test "work in a worktree leaves the project's own files alone", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "risky")

    File.write!(Path.join(worktree.path, "README.md"), "changed by the agent\n")
    File.write!(Path.join(worktree.path, "new.txt"), "brand new\n")

    assert File.read!(Path.join(project.path, "README.md")) == "base\n"
    refute File.exists?(Path.join(project.path, "new.txt"))

    assert %{files: 1, insertions: 1, deletions: 1, untracked: 1, commits: 0} =
             Worktrees.work(worktree)
  end

  test "keeping a worktree removes the directory but not the branch", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "keep me")
    File.write!(Path.join(worktree.path, "README.md"), "uncommitted work\n")

    {:ok, kept} = Worktrees.keep(worktree.id)

    assert kept.status == :kept
    refute File.exists?(worktree.path)
    assert worktree.branch in branches(project.path)
  end

  test "discarding a worktree removes the branch too", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "throwaway")

    {:ok, discarded} = Worktrees.discard(worktree.id)

    assert discarded.status == :discarded
    refute File.exists?(worktree.path)
    refute worktree.branch in branches(project.path)
  end

  # Worktrees are created beside the repository, so that destination has to be
  # inside the allowed roots like any other workspace. The suite's own
  # workspaces sit inside this repository, which makes them a good stand-in
  # for a project whose repository root is somewhere Khymeia may not write.
  test "a destination outside the allowed workspace roots is refused", _context do
    {:ok, nested} = Projects.create(%{"path" => workspace!()})

    assert {:error, {:invalid, %{worktree: message}}} = Worktrees.create(nested, "anything")
    assert message =~ "not inside the allowed workspace roots"
  end

  test "a terminal in a worktree runs there and still belongs to the project", %{
    project: project
  } do
    {:ok, worktree} = Worktrees.create(project, "terminal here")

    {:ok, terminal} =
      Terminals.start(%{"harness" => "fake", "worktree" => worktree.id, "workspace" => nil})

    assert terminal.workspace == worktree.path
    assert terminal.project_id == project.id
    assert terminal.worktree_id == worktree.id

    eventually(fn -> Terminals.alive?(terminal.id) end)
    Terminals.stop(terminal.id)
  end

  test "a released worktree cannot host a new terminal", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "gone")
    {:ok, _} = Worktrees.discard(worktree.id)

    assert {:error, {:invalid, %{worktree: message}}} =
             Terminals.start(%{"harness" => "fake", "worktree" => worktree.id})

    assert message =~ "released"
  end

  defp branches(repository) do
    {out, 0} =
      System.cmd(System.find_executable("git"), [
        "-C",
        repository,
        "branch",
        "--format=%(refname:short)"
      ])

    String.split(out, "\n", trim: true)
  end
end
