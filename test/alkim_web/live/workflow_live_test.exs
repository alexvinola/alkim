defmodule AlkimWeb.WorkflowLiveTest do
  use AlkimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Alkim.RuntimeCase,
    only: [
      workspace!: 0,
      git_workspace!: 0,
      start_workflow!: 3,
      await_workflow: 2,
      eventually: 1,
      pick_workspace: 2
    ]

  alias Alkim.Workflow

  @moduletag :capture_log

  test "chat and workflow modes are one click apart", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/sessions/new")

    assert {:error, {:live_redirect, %{to: "/workflows/new"}}} =
             view |> element(".a-tabs a", "Workflow") |> render_click()
  end

  test "the workflow form maps roles to detected harnesses and starts a run", %{conn: conn} do
    ws = workspace!()
    {:ok, view, html} = live(conn, ~p"/workflows/new")

    # Only detected harnesses are offered (tests only have the fake one).
    assert html =~ "Implementer" and html =~ "Advisor" and html =~ "Auditor"
    assert has_element?(view, "#role_auditor_harness option[value=fake]")
    refute has_element?(view, "#role_auditor_harness option[value=claude]")
    assert render(view) =~ "read-only NOT guaranteed"

    roles = %{
      implementer: %{harness: "fake", model: "success"},
      advisor: %{harness: "none"},
      auditor: %{harness: "fake", model: "audit-pass"}
    }

    pick_workspace(view, ws)

    {:error, {:live_redirect, %{to: "/workflows/" <> id}}} =
      view
      |> form("#new-workflow", workflow: %{task: "Build X", roles: roles})
      |> render_submit()

    assert {:ok, %{task: "Build X"}, _} = Workflow.get(id)
  end

  # Isolation and *which branch* are two decisions, not one: a run may want
  # its own branch cut from HEAD, or a directory of its own on a branch that
  # already exists.
  test "a run can be started on a new branch or on an existing one", %{conn: conn} do
    ws = git_workspace!()
    git = System.find_executable("git")
    {_, 0} = System.cmd(git, ["-C", ws, "branch", "spike"])

    {:ok, view, _} = live(conn, ~p"/workflows/new")
    pick_workspace(view, ws)

    # The branch question only exists once a new worktree is asked for.
    html = view |> form("#new-workflow", workflow: %{worktree: ""}) |> render_change()
    refute html =~ "workflow[worktree_branch]"

    html = view |> form("#new-workflow", workflow: %{worktree: "new"}) |> render_change()
    assert html =~ "workflow[worktree_branch]"
    assert has_element?(view, ~s([id="workflow[worktree_branch]"] option[value="spike"]))

    # main is checked out by the workspace itself, and git refuses a second
    # worktree on it, so it is offered as unavailable rather than as a trap.
    assert has_element?(view, ~s([id="workflow[worktree_branch]"] option[value="main"][disabled]))

    {:error, {:live_redirect, %{to: "/workflows/" <> id}}} =
      view
      |> form("#new-workflow",
        workflow: %{
          task: "Continue the spike",
          worktree: "new",
          worktree_branch: "spike",
          roles: %{
            implementer: %{harness: "fake", model: "success"},
            advisor: %{harness: "none"},
            auditor: %{harness: "fake", model: "audit-pass"}
          }
        }
      )
      |> render_submit()

    {:ok, run, _} = Workflow.get(id)
    worktree = Alkim.Worktrees.get(run.worktree_id)
    assert worktree.branch == "spike"
    assert run.workspace == worktree.path
    refute run.workspace == ws

    Workflow.stop(id)
  end

  test "validation errors are shown next to their fields", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/workflows/new")

    html = view |> form("#new-workflow", workflow: %{task: ""}) |> render_submit()
    assert html =~ "describe the task"
  end

  test "the run page follows the workflow live, with steps and timeline", %{conn: conn} do
    run =
      start_workflow!(
        workspace!(),
        %{implementer: "success", auditor: "audit-fix-once", advisor: nil},
        %{}
      )

    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}")

    await_workflow(run.id, "workflow.completed")
    eventually(fn -> has_element?(view, "#workflow-status", "completed") end)

    # The timeline is the landing tab: what happened, in order.
    html = render(view)
    assert html =~ "Found 2 issue(s)"
    assert html =~ "Missing input validation"
    assert html =~ "Workflow completed."

    # Steps, terminals and changes are cuts of the same run behind their tabs.
    steps = view |> element(~s(a[href$="/steps"])) |> render_click()
    assert steps =~ "Re-audit"

    agents = view |> element(~s(a[href$="/terminals"])) |> render_click()
    assert agents =~ "Implementer"
    assert agents =~ "Auditor"

    # One row per conversation, not per step — and that distinction shows the
    # design: the implementer implemented and then fixed on the *same*
    # session, while each audit round gets a fresh, independent one.
    agents = AlkimWeb.WorkflowLive.agents(elem(Workflow.get(run.id), 2))

    assert [implementer] = Enum.filter(agents, &(&1.role == "implementer"))
    assert implementer.steps == 2
    assert [%{steps: 1}, %{steps: 1}] = Enum.filter(agents, &(&1.role == "auditor"))
  end

  # Two clients on one conversation is how you corrupt it, so the CLI can
  # only be opened on an agent that is not mid-turn.
  test "the CLI cannot be opened on an agent that is working", %{conn: conn} do
    run =
      start_workflow!(workspace!(), %{implementer: "hang", advisor: nil}, %{
        workflow: "simple-coding"
      })

    # "step.started" fires before the step has a session, and an agent *is*
    # its session, so wait for that rather than for the step.
    eventually(fn ->
      {:ok, _run, steps} = Workflow.get(run.id)
      Enum.any?(steps, & &1.session_id)
    end)

    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}/terminals")
    assert render(view) =~ "open_agent_terminal"

    html = view |> element(~s(button[phx-click="open_agent_terminal"])) |> render_click()
    assert html =~ "mid-turn"

    Workflow.stop(run.id)
  end

  # The point of the tab: a role is shown as its own terminal, in this page.
  # Nothing navigates away, and the terminal belongs to the run, so coming
  # back to it finds the same one.
  test "taking over a role puts its CLI in the run page", %{conn: conn} do
    run =
      start_workflow!(
        workspace!(),
        %{implementer: "success", auditor: "audit-pass", advisor: nil},
        %{}
      )

    await_workflow(run.id, "workflow.completed")

    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}/terminals")

    # Until a human takes over there is no terminal: the run drove its agents
    # headlessly, which is what let Alkim relay between the roles.
    refute has_element?(view, "[phx-hook=EmbeddedTerminal]")
    assert render(view) =~ "Take over"

    view |> element(~s(button[phx-click="open_agent_terminal"])) |> render_click()

    assert has_element?(view, "[phx-hook=EmbeddedTerminal]")
    assert [terminal] = Alkim.Terminals.list_for_workflow(run.id)
    assert terminal.role == "implementer"
    assert terminal.workflow_id == run.id

    # It continues the implementer's conversation, not a fresh one.
    [implementer] =
      run.id
      |> Workflow.get()
      |> elem(2)
      |> AlkimWeb.WorkflowLive.agents()
      |> Enum.filter(&(&1.role == "implementer"))

    assert terminal.harness_ref == implementer.harness_ref

    # Reopening the page finds the same terminal rather than starting another.
    {:ok, again, _html} = live(conn, ~p"/workflows/#{run.id}/terminals")
    assert has_element?(again, "#terminal-#{terminal.id}")
    assert [^terminal] = Alkim.Terminals.list_for_workflow(run.id)

    Alkim.Terminals.delete(terminal.id)
  end

  test "a human answers a clarification from the run page", %{conn: conn} do
    run =
      start_workflow!(workspace!(), %{implementer: "ask-human", advisor: nil}, %{
        workflow: "simple-coding"
      })

    await_workflow(run.id, "workflow.waiting")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}")

    assert render(view) =~ "Should the new endpoint be public?"
    view |> form("#human-reply", reply: "Internal only") |> render_submit()

    eventually(fn -> has_element?(view, "#workflow-status", "completed") end)
    assert render(view) =~ "Internal only"
  end

  test "max iterations offers another iteration or acceptance", %{conn: conn} do
    run =
      start_workflow!(
        workspace!(),
        %{implementer: "success", auditor: "audit-findings", advisor: nil},
        %{max_iterations: 1}
      )

    await_workflow(run.id, "workflow.waiting")
    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}")

    assert has_element?(view, "#resume-workflow", "Run one more iteration")
    view |> element("#complete-workflow") |> render_click()
    eventually(fn -> has_element?(view, "#workflow-status", "completed") end)
  end

  # A run with three roles would otherwise fill the list with four entries:
  # itself plus one per agent. The run stands for the agents inside it.
  test "a workflow's agents are shown by the workflow, not beside it", %{conn: conn} do
    run =
      start_workflow!(workspace!(), %{implementer: "hang", advisor: nil}, %{
        workflow: "simple-coding"
      })

    {:ok, view, _html} = live(conn, ~p"/sessions")

    eventually(fn -> has_element?(view, "#workflow-#{run.id}", "agent(s)") end)

    # The implementer is running, but it has no entry of its own.
    assert [agent] = Alkim.Runtime.list_live()
    assert agent.metadata["role"] == "implementer"
    refute has_element?(view, "#session-#{agent.id}")

    Workflow.stop(run.id)
    eventually(fn -> has_element?(view, "#workflow-#{run.id}", "stopped") end)
  end
end
