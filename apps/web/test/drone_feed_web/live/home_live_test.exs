defmodule DroneFeedWeb.HomeLiveTest do
  use DroneFeedWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "GET / shows landing for anonymous users", %{conn: conn} do
    {:ok, _lv, html} = live(conn, ~p"/")

    assert html =~ "DroneFeed"
    assert html =~ "Request an account"
    assert html =~ "Log in"
  end

  test "GET / redirects authenticated users to flights", %{conn: conn} do
    %{conn: conn} = register_and_log_in_user(%{conn: conn})

    assert {:error, {:live_redirect, %{to: "/flights"}}} = live(conn, ~p"/")
  end
end
