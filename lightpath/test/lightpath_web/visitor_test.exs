defmodule LightpathWeb.VisitorTest do
  use LightpathWeb.ConnCase, async: true

  test "a new browser gets an id, and keeps it", %{conn: conn} do
    conn = get(conn, ~p"/")
    id = get_session(conn, "visitor")
    assert id =~ ~r/^[0-9a-f]{32}$/

    again = conn |> recycle() |> get(~p"/")
    assert get_session(again, "visitor") == id
  end

  test "two browsers get different ids", %{conn: conn} do
    a = conn |> get(~p"/") |> get_session("visitor")
    b = build_conn() |> get(~p"/") |> get_session("visitor")
    assert a != b
  end
end
