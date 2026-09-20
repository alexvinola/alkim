defmodule Alkim.WorktreesTest do
  use Alkim.RuntimeCase, async: false

  import Alkim.RuntimeCase, only: [git_workspace!: 0, workspace!: 0, eventually: 1]

  alias Alkim.{Projects, Terminals, Worktrees}

  setup do
    path = git_workspace!()
    {:ok, project} = Projects.create(%{"path" => path})
    {:ok, project: project}
  end

  test "a worktree is its own directory on its own branch", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "add search")

    assert File.dir?(worktree.path)
    assert worktree.branch =~ ~r"^alkim/add-search-"
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
  # for a project whose repository root is somewhere Alkim may not write.
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

  test "a session can claim a fresh worktree and runs inside it", %{project: project} do
    {:ok, session} =
      Alkim.Runtime.start_session(%{
        "harness" => "fake",
        "workspace" => project.path,
        "prompt" => "isolate this work please",
        "worktree" => "new"
      })

    assert [worktree] = Worktrees.list_for_project(project.id)
    assert session.workspace == worktree.path
    assert session.worktree_id == worktree.id
    assert session.project_id == project.id
    # The branch is named after the prompt, so it is recognisable in git.
    assert worktree.branch =~ "isolate-this-work"

    Alkim.Runtime.stop_session(session.id)
  end

  test "an existing worktree can be reused instead of making another", %{project: project} do
    {:ok, worktree} = Worktrees.create(project, "shared")

    {:ok, session} =
      Alkim.Runtime.start_session(%{
        "harness" => "fake",
        "workspace" => project.path,
        "prompt" => "reuse it",
        "worktree" => worktree.id
      })

    assert session.workspace == worktree.path
    assert [_only_one] = Worktrees.list_for_project(project.id)

    Alkim.Runtime.stop_session(session.id)
  end

  test "asking for isolation where it is impossible is refused, not improvised" do
    plain = workspace!()

    assert {:error, {:invalid, %{worktree: message}}} =
             Alkim.Runtime.start_session(%{
               "harness" => "fake",
               "workspace" => plain,
               "prompt" => "nowhere to isolate",
               "worktree" => "new"
             })

    assert message =~ "not inside the allowed workspace roots"
    assert Alkim.Runtime.list_live() == []
  end

  test "a workflow run gets its own worktree, so roles cannot collide", %{project: project} do
    run =
      Alkim.RuntimeCase.start_workflow!(
        project.path,
        %{implementer: "success", advisor: nil, auditor: "audit-pass"},
        %{workflow: "coding-with-audit", worktree: "new", task: "add a greeting"}
      )

    assert [worktree] = Worktrees.list_for_project(project.id)
    assert run.workspace == worktree.path
    assert run.worktree_id == worktree.id
    assert worktree.branch =~ "add-a-greeting"

    Alkim.Workflow.stop(run.id)
  end

  test "offer/1 says whether isolation is possible before it is chosen", %{project: project} do
    assert :ok = Worktrees.offer(project.path)
    assert {:unavailable, reason} = Worktrees.offer(workspace!())
    assert reason =~ "workspace roots"
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
