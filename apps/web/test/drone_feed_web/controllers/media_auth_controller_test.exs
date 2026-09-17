defmodule DroneFeedWeb.MediaAuthControllerTest do
  use DroneFeedWeb.ConnCase, async: true

  import DroneFeed.AccountsFixtures

  alias DroneFeed.Flights
  alias DroneFeed.Streaming

  test "returns 401 for empty credentials", %{conn: conn} do
    conn =
      post(conn, ~p"/api/mediamtx/auth", %{
        "action" => "read",
        "path" => "vod/unknown",
        "user" => "",
        "password" => ""
      })

    assert response(conn, 401)
  end

  test "returns 200 for active live session credentials", %{conn: conn} do
    scope = user_scope_fixture()
    {:ok, session} = Streaming.create_live_session(scope, %{"name" => "Pad"})

    conn =
      post(conn, ~p"/api/mediamtx/auth", %{
        "action" => "publish",
        "path" => "live/#{session.id}",
        "user" => "drone",
        "password" => session.stream_key
      })

    assert response(conn, 200)
  end

  test "returns 403 for unpublished flight", %{conn: conn} do
    scope = user_scope_fixture()
    video = tmp_file("x.mp4", "data")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "X"}, %{video: video})

    conn =
      post(conn, ~p"/api/mediamtx/auth", %{
        "action" => "read",
        "path" => "vod/#{flight.id}",
        "user" => "drone",
        "password" => flight.stream_key
      })

    assert response(conn, 403)
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
