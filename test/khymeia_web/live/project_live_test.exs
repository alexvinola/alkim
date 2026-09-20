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

  test "the overview opens a terminal in the project's folder", %{conn: conn, project: project} do
    {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")

    # The overview starts work, it is not a chat: no prompt box.
    refute html =~ ~s(id="composer")

    view |> form("#open-terminal", terminal: %{harness: "fake"}) |> render_submit()

    assert [terminal] = Khymeia.Terminals.list_for_project(project.id)
    assert terminal.workspace == project.path
    assert Khymeia.Terminals.alive?(terminal.id)

    eventually(fn -> has_element?(view, "#card-#{terminal.id}") end)
  end

  test "a terminal keeps its output after its process is gone", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")

    view |> form("#open-terminal", terminal: %{harness: "fake"}) |> render_submit()
    [terminal] = Khymeia.Terminals.list_for_project(project.id)

    eventually(fn -> Khymeia.Terminals.attach(terminal.id) |> elem(2) =~ "fake>" end)
    Khymeia.Terminals.stop(terminal.id)
    eventually(fn -> not Khymeia.Terminals.alive?(terminal.id) end)

    # Re-attaching reads the saved log, which is what survives a restart.
    {:ok, _terminal, scrollback} = Khymeia.Terminals.attach(terminal.id)
    assert scrollback =~ "fake>"
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
  # handle_params runs on the disconnected render too, and starting an OS
  # process there would launch the harness twice for one terminal.
  test "a page load never starts a terminal twice", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    view |> form("#open-terminal", terminal: %{harness: "fake"}) |> render_submit()
    [terminal] = Khymeia.Terminals.list_for_project(project.id)

    Khymeia.Terminals.stop(terminal.id)
    eventually(fn -> not Khymeia.Terminals.alive?(terminal.id) end)

    # The static render alone must not bring the harness back.
    static = get(conn, ~p"/projects/#{project.id}/terminal?t=#{terminal.id}")
    assert html_response(static, 200)
    refute Khymeia.Terminals.alive?(terminal.id)

    # Connecting does, exactly once.
    {:ok, _view, _html} = live(conn, ~p"/projects/#{project.id}/terminal?t=#{terminal.id}")
    eventually(fn -> Khymeia.Terminals.alive?(terminal.id) end)
    assert [_one] = Khymeia.Terminals.list_for_project(project.id)
  end

  test "deleting a terminal from the UI removes its saved output", %{
    conn: conn,
    project: project
  } do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
    view |> form("#open-terminal", terminal: %{harness: "fake"}) |> render_submit()
    [terminal] = Khymeia.Terminals.list_for_project(project.id)
    path = Khymeia.Terminals.Log.path(terminal.id)
    eventually(fn -> File.exists?(path) end)

    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/terminal?t=#{terminal.id}")
    view |> element("#delete-terminal") |> render_click()

    assert Khymeia.Terminals.get(terminal.id) == nil
    refute File.exists?(path)
  end

  test "the git tab reports what git knows about the folder", %{conn: conn, project: project} do
    {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}/git")

    eventually(fn -> render(view) =~ "Branch" end)
    refute render(view) =~ "Reading the repository…"
  end

  describe "worktrees" do
    setup do
      path = Khymeia.RuntimeCase.git_workspace!()
      {:ok, project} = Projects.create(%{"path" => path})
      {:ok, repo_project: project}
    end

    test "creating one from the overview isolates it on its own branch", %{
      conn: conn,
      repo_project: project
    } do
      {:ok, view, html} = live(conn, ~p"/projects/#{project.id}")
      assert html =~ "Khymeia never merges one"

      view |> form("#create-worktree", worktree: %{name: "try something"}) |> render_submit()

      assert [worktree] = Khymeia.Worktrees.list_for_project(project.id)
      assert File.dir?(worktree.path)
      assert render(view) =~ worktree.branch
    end

    test "keeping leaves the branch, discarding does not", %{conn: conn, repo_project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      view |> form("#create-worktree", worktree: %{name: "keep"}) |> render_submit()
      view |> form("#create-worktree", worktree: %{name: "drop"}) |> render_submit()

      [drop, keep] = Khymeia.Worktrees.list_for_project(project.id) |> Enum.sort_by(& &1.branch)

      view |> element("#wt-keep-#{keep.id}") |> render_click()
      view |> element("#wt-discard-#{drop.id}") |> render_click()

      assert Khymeia.Worktrees.get(keep.id).status == :kept
      assert Khymeia.Worktrees.get(drop.id).status == :discarded
      refute File.exists?(keep.path)
      refute File.exists?(drop.path)
    end

    test "a terminal can be opened inside a worktree", %{conn: conn, repo_project: project} do
      {:ok, view, _html} = live(conn, ~p"/projects/#{project.id}")
      view |> form("#create-worktree", worktree: %{name: "work here"}) |> render_submit()
      [worktree] = Khymeia.Worktrees.list_for_project(project.id)

      view |> element("#wt-terminal-#{worktree.id}") |> render_click()

      assert [terminal] = Khymeia.Terminals.list_for_project(project.id)
      assert terminal.workspace == worktree.path
      assert terminal.worktree_id == worktree.id
      eventually(fn -> Khymeia.Terminals.alive?(terminal.id) end)
    end
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
