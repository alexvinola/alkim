defmodule AlkimWeb.WorkflowLiveTest do
  use AlkimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Alkim.RuntimeCase,
    only: [
      workspace!: 0,
      start_workflow!: 3,
      await_workflow: 2,
      eventually: 1,
      eventually: 2,
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

    # Steps, agents and changes are cuts of the same run behind their tabs.
    steps = view |> element(~s(a[href$="/steps"])) |> render_click()
    assert steps =~ "Re-audit"

    agents = view |> element(~s(a[href$="/agents"])) |> render_click()
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

    {:ok, view, _html} = live(conn, ~p"/workflows/#{run.id}/agents")
    assert render(view) =~ "open_agent_terminal"

    html = view |> element(~s(button[phx-click="open_agent_terminal"])) |> render_click()
    assert html =~ "mid-turn"

    Workflow.stop(run.id)
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
