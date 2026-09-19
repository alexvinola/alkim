defmodule KhymeiaWeb.ProvidersLiveTest do
  use KhymeiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Khymeia.Providers

  @secret "fk-live_0123456789abcdef"

  test "creates a Keychain-backed profile without the key ever reaching the page or DB", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/providers")
    assert render(view) =~ "No provider profiles yet"

    view |> form("#profile-form", profile: %{target: "fake:demo"}) |> render_change()

    view
    |> form("#profile-form", profile: %{target: "fake:demo", credential: "keychain"})
    |> render_change()

    assert has_element?(view, "#profile_secret[type=password]")

    view
    |> form("#profile-form",
      profile: %{
        target: "fake:demo",
        name: "demo",
        credential: "keychain",
        secret: @secret,
        settings: %{region: "eu-west-1"}
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "Saved demo"
    assert html =~ "API key stored in the macOS Keychain"
    refute html =~ @secret

    [profile] = Providers.list()
    assert profile.settings == %{"region" => "eu-west-1"}
    refute inspect(profile) =~ @secret
  end

  test "AWS access keys are entered in a form, stored in the Keychain and can be forgotten", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/providers")

    view
    |> form("#profile-form", profile: %{target: "fake:demo", credential: "aws_keys"})
    |> render_change()

    assert has_element?(view, "#profile_aws_secret_access_key[type=password]")

    html =
      view
      |> form("#profile-form",
        profile: %{
          target: "fake:demo",
          name: "aws",
          credential: "aws_keys",
          aws_access_key_id: "nope",
          aws_secret_access_key: "x"
        }
      )
      |> render_submit()

    assert html =~ "the access key ID looks wrong"

    view
    |> form("#profile-form",
      profile: %{
        target: "fake:demo",
        name: "aws",
        credential: "aws_keys",
        aws_access_key_id: "AKIAIOSFODNN7EXAMPLE",
        aws_secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      }
    )
    |> render_submit()

    html = render(view)
    assert html =~ "AWS access keys stored in the macOS Keychain"
    refute html =~ "wJalrXUtnFEMI"

    [p] = Providers.list()
    view |> element("#profile-#{p.id} button", "Forget credential") |> render_click()
    assert render(view) =~ "no AWS access keys in the Keychain"
  end

  test "shows validation errors and edits and deletes profiles", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/providers")

    html =
      view
      |> form("#profile-form", profile: %{target: "fake:demo", name: "", credential: "env"})
      |> render_submit()

    assert html =~ "can&#39;t be blank"
    assert html =~ "name the environment variable"

    {:ok, p} = Providers.save(%{name: "old", harness: :fake, kind: :demo})
    {:ok, view, _} = live(conn, ~p"/providers?edit=#{p.id}")
    view |> form("#profile-form", profile: %{name: "renamed"}) |> render_submit()
    assert render(view) =~ "renamed"

    view |> element("#profile-#{p.id} button", "Delete") |> render_click()
    assert Providers.list() == []
  end

  test "profiles appear as harness choices in the new-session form", %{conn: conn} do
    {:ok, p} = Providers.save(%{name: "demo", harness: :fake, kind: :demo})
    {:ok, view, _} = live(conn, ~p"/sessions/new")

    assert has_element?(
             view,
             ~s(#session_harness option[value="fake@#{p.id}"]),
             "Fake harness · Demo provider · demo"
           )

    html =
      view |> element("#new-session") |> render_change(%{session: %{harness: "fake@#{p.id}"}})

    assert html =~ "model inference goes to Demo provider"
  end
end
