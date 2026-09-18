defmodule KhymeiaWeb.Plugs.LocalOnlyTest do
  use KhymeiaWeb.ConnCase, async: true

  test "requests addressed to a non-local host are refused (DNS rebinding)", %{conn: conn} do
    conn = %{conn | host: "evil.example"} |> get(~p"/")
    assert conn.status == 403
  end

  test "localhost is served", %{conn: conn} do
    for host <- ["localhost", "127.0.0.1"] do
      assert %{status: 200} = %{conn | host: host} |> get(~p"/")
    end
  end
end
