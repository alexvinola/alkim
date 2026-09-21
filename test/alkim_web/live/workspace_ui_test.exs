defmodule AlkimWeb.WorkspaceUITest do
  use AlkimWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Alkim.RuntimeCase, only: [workspace!: 0, eventually: 1]

  alias Alkim.{Projects, Repo, Terminals}
  alias Alkim.Terminals.Terminal

  test "the dashboard follows terminal activity without a reload", %{conn: conn} do
    workspace = workspace!()
    {:ok, view, _html} = live(conn, ~p"/")
    {:ok, terminal} = Terminals.start(%{"harness" => "fake", "workspace" => workspace})

    eventually(fn -> has_element?(view, "#active-#{terminal.id}") end)
    assert has_element?(view, "#active-work-count", "1")
    refute has_element?(view, "#active-work-empty")

    Terminals.stop(terminal.id)
    eventually(fn -> not has_element?(view, "#active-#{terminal.id}") end)
    assert has_element?(view, "#active-work-empty")
    assert has_element?(view, "#active-work-count", "0")
  end

  test "active terminals remain visible beyond the recent history window", %{conn: conn} do
    workspace = workspace!()
    {:ok, project} = Projects.create(%{"path" => workspace})
    now = DateTime.utc_now()

    terminal = terminal!(project, :running, DateTime.add(now, -60))
    for offset <- 1..30, do: terminal!(project, :exited, DateTime.add(now, offset))

    {:ok, dashboard, _html} = live(conn, ~p"/")
    assert has_element?(dashboard, "#active-#{terminal.id}")
    {:ok, sessions, _html} = live(conn, ~p"/sessions")
    assert has_element?(sessions, "#active-session-list #terminal-#{terminal.id}")
  end

  test "search and type filters compose and survive live updates", %{conn: conn} do
    workspace = workspace!()
    {:ok, project} = Projects.create(%{"path" => workspace})
    terminal = terminal!(project, :running, DateTime.utc_now())
    {:ok, view, _html} = live(conn, ~p"/sessions")

    view |> element("#filter-terminal") |> render_click()
    view |> form("#session-search", search: %{query: "  FAKE  "}) |> render_change()
    assert has_element?(view, "#terminal-#{terminal.id}")

    view |> form("#session-search", search: %{query: "no-matching-task"}) |> render_change()
    refute has_element?(view, "#terminal-#{terminal.id}")

    send(view.pid, {:terminal_status, terminal})
    refute has_element?(view, "#terminal-#{terminal.id}")
    assert has_element?(view, "#filter-terminal[aria-pressed=true]")

    view |> form("#session-search", search: %{query: Path.basename(workspace)}) |> render_change()
    assert has_element?(view, "#terminal-#{terminal.id}")
    view |> element("#filter-workflow") |> render_click()
    refute has_element?(view, "#terminal-#{terminal.id}")
    view |> element("#filter-all") |> render_click()
    assert has_element?(view, "#terminal-#{terminal.id}")
  end

  defp terminal!(project, status, at) do
    Repo.insert!(%Terminal{
      id: Ecto.UUID.generate(),
      project_id: project.id,
      workspace: project.path,
      harness: "fake",
      status: status,
      started_at: at,
      inserted_at: at,
      updated_at: at
    })
  end
end
