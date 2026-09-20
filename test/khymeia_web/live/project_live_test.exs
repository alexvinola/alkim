defmodule KhymeiaWeb.ProjectLiveTest do
  use KhymeiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Khymeia.RuntimeCase, only: [workspace!: 0, start_fake!: 2, eventually: 1]

  alias Khymeia.Projects

  setup do
    workspace = workspace!()
    {:ok, project} = Projects.create(%{"path" => workspace})
    {:ok, project: project, workspace: workspace}
  end

  test "the projects page lists projects and the sidebar links to them", %{
    conn: conn,
    project: project
  } do
    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ project.name
    assert html =~ "Add project"
    assert html =~ ~s(id="nav-project-#{project.id}")
  end

  test "the composer starts a session in the project's folder", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    assert {:error, {:live_redirect, %{to: "/sessions/" <> id}}} =
             view
             |> form("#composer", start: %{harness: "fake", prompt: "do the thing"})
             |> render_submit()

    assert {:ok, session, _events} = Khymeia.Runtime.get_session(id)
    assert session.workspace == project.path
    assert session.project_id == project.id
  end

  test "an empty prompt is refused without starting anything", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    html = view |> form("#composer", start: %{harness: "fake", prompt: "  "}) |> render_submit()

    assert html =~ "write a prompt"
    assert Khymeia.Runtime.list_live() == []
  end

  test "active work shows up in the project and in the sidebar", %{
    conn: conn,
    project: project,
    workspace: workspace
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    session = start_fake!(workspace, "hang")

    eventually(fn -> has_element?(view, "#card-#{session.id}") end)
    eventually(fn -> has_element?(view, "#nav-entry-#{session.id}") end)

    Khymeia.Runtime.stop_session(session.id)
    eventually(fn -> has_element?(view, "#recent-#{session.id}", "stopped") end)
  end

  # The test workspaces live inside this repository, so git has something to
  # say about them; a folder outside any repository renders the other branch.
  test "the git tab reports what git knows about the folder", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/git")

    eventually(fn -> render(view) =~ "Branch" end)
    refute render(view) =~ "Reading the repository…"
  end

  test "renaming keeps the folder and removing keeps history", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/settings")

    view |> form("#project-settings form", project: %{name: "Renamed"}) |> render_submit()
    assert Projects.get(project.id).name == "Renamed"
    assert Projects.get(project.id).path == project.path

    assert {:error, {:live_redirect, %{to: "/"}}} =
             view |> element("button", "Remove") |> render_click()

    assert Projects.get(project.id) == nil
  end
end
