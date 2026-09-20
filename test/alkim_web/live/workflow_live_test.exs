defmodule AlkimWeb.WorkflowLiveTest do
  use AlkimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Alkim.RuntimeCase,
    only: [workspace!: 0, start_workflow!: 3, await_workflow: 2, eventually: 1, pick_workspace: 2]

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

    html = render(view)
    assert html =~ "Found 2 issue(s)"
    assert html =~ "Missing input validation"
    assert has_element?(view, "#workflow-steps", "Re-audit")
    assert html =~ "Workflow completed."
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
