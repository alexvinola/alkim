defmodule KhymeiaWeb.SessionLiveTest do
  use KhymeiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  import Khymeia.RuntimeCase,
    only: [workspace!: 0, start_fake!: 2, await_event: 2, eventually: 1, pick_workspace: 2]

  alias Khymeia.Runtime

  test "the sessions view lists terminals alongside sessions", %{conn: conn} do
    ws = workspace!()
    {:ok, terminal} = Khymeia.Terminals.start(%{"harness" => "fake", "workspace" => ws})

    {:ok, view, _html} = live(conn, ~p"/sessions")

    eventually(fn -> has_element?(view, "#terminal-#{terminal.id}") end)
    assert render(view) =~ "Terminal"

    Khymeia.Terminals.stop(terminal.id)
    eventually(fn -> has_element?(view, "#terminal-#{terminal.id}", "completed") end)
  end

  test "the sessions view lists live sessions, updating in real time", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/sessions")

    assert html =~ "Fake harness"
    assert html =~ "No active sessions"

    session = start_fake!(workspace!(), "hang")
    await_event(session.id, :started)

    # Pushed via PubSub; no reload, no polling.
    eventually(fn -> has_element?(view, "#session-#{session.id}", "running") end)

    Runtime.stop_session(session.id)
    eventually(fn -> has_element?(view, "#recent-#{session.id}", "stopped") end)
  end

  test "the new-session form starts a session through the runtime", %{conn: conn} do
    ws = workspace!()
    {:ok, view, _html} = live(conn, ~p"/sessions/new")

    pick_workspace(view, ws)
    assert has_element?(view, "#workspace-picker-trigger", Path.basename(ws))
    view |> element("#new-session") |> render_change(%{session: %{harness: "fake"}})
    assert has_element?(view, "#session_model option[value=hang]")
    # The fake's list is closed, so no free-form model entry is offered.
    refute has_element?(view, "#session_model option[value=__custom__]")

    {:error, {:live_redirect, %{to: "/sessions/" <> id}}} =
      view
      |> form("#new-session", session: %{harness: "fake", model: "success", prompt: "Say hi"})
      |> render_submit()

    assert {:ok, %{prompt: "Say hi", harness: :fake}, _} = Runtime.get_session(id)
  end

  test "the new-session form shows validation errors", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sessions/new")

    html =
      view |> form("#new-session", session: %{harness: "fake", prompt: ""}) |> render_submit()

    assert html =~ "write a prompt"
  end

  describe "workspace picker" do
    test "browses folders inside the roots, marks git repos, and filters", %{conn: conn} do
      ws = workspace!()
      File.mkdir_p!(Path.join(ws, "alpha/.git"))
      File.mkdir_p!(Path.join(ws, "beta"))
      File.mkdir_p!(Path.join(ws, ".hidden"))

      {:ok, view, _} = live(conn, ~p"/sessions/new")
      pick_workspace(view, ws)
      view |> element("#workspace-picker-trigger") |> render_click()

      list = view |> element("#workspace-picker-list") |> render()
      assert list =~ "alpha" and list =~ "beta"
      assert list =~ "git"
      refute list =~ ".hidden"

      view |> element("#workspace-picker form") |> render_change(%{filter: "alp"})
      list = view |> element("#workspace-picker-list") |> render()
      assert list =~ "alpha"
      refute list =~ "beta"

      view
      |> element(~s(#workspace-picker-list button[phx-value-path="#{ws}/alpha"]))
      |> render_click()

      view |> element("#workspace-picker-select") |> render_click()

      assert has_element?(
               view,
               ~s(input[type=hidden][name="session[workspace]"][value="#{ws}/alpha"])
             )

      refute has_element?(view, ".k-modal")
    end

    test "cannot browse or select outside the allowed roots", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sessions/new")
      view |> element("#workspace-picker-trigger") |> render_click()

      # Forged events, as if a client sent any path it liked.
      view
      |> element("#workspace-picker-list li:first-child button")
      |> render_click(%{"path" => "/etc"})

      assert render(view) =~ "outside the allowed workspace roots"

      view |> element("#workspace-picker-select") |> render_click(%{"path" => "/"})
      assert render(view) =~ "outside the allowed workspace roots"
      assert has_element?(view, ".k-modal")
      refute has_element?(view, ~s(input[type=hidden][value="/"]))
    end

    test "closes with Escape without changing the value", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/sessions/new")
      before = view |> element("#workspace-picker-value") |> render()
      view |> element("#workspace-picker-trigger") |> render_click()
      assert has_element?(view, ".k-modal")

      view |> element(".k-modal-backdrop") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, ".k-modal")
      assert view |> element("#workspace-picker-value") |> render() == before
    end
  end

  test "session page streams activity and can stop the session", %{conn: conn} do
    session = start_fake!(workspace!(), "hang")
    {:ok, view, html} = live(conn, ~p"/sessions/#{session.id}")

    assert html =~ "test prompt"
    eventually(fn -> render(view) =~ "Working on a very long task" end)
    assert has_element?(view, "#session-status", "running")

    view |> element("#stop-session") |> render_click()
    eventually(fn -> has_element?(view, "#session-status", "stopped") end)
    assert render(view) =~ "session.stopped"
    refute has_element?(view, "#stop-session")
  end

  test "session page sends follow-up messages when the harness is waiting", %{conn: conn} do
    session = start_fake!(workspace!(), "success")
    await_event(session.id, :waiting)
    {:ok, view, _html} = live(conn, ~p"/sessions/#{session.id}")

    view |> form("#composer", message: "second turn") |> render_submit()
    eventually(fn -> render(view) =~ "You said: second turn" end)
  end

  test "unknown sessions redirect to the dashboard", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} =
             live(conn, ~p"/sessions/#{Ecto.UUID.generate()}")
  end
end
