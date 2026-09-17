defmodule DroneFeedWeb.MetadataControllerTest do
  use DroneFeedWeb.ConnCase, async: true

  import DroneFeed.AccountsFixtures

  alias DroneFeed.Flights

  test "serves srt telemetry when publishing with valid key", %{conn: conn} do
    scope = user_scope_fixture()
    video = tmp_file("clip.mp4", "videodata")
    srt = tmp_file("clip.srt", "GPS(N) 1.0\n")

    {:ok, flight} =
      Flights.create_flight(scope, %{"name" => "Meta"}, %{video: video, srt: srt})

    {:ok, flight} = Flights.set_publishing(scope, flight.id, true)

    conn =
      get(conn, ~p"/api/streams/vod/#{flight.id}/metadata/srt", %{"key" => flight.stream_key})

    assert response(conn, 200) =~ "GPS"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
  end

  test "rejects metadata pull when not publishing", %{conn: conn} do
    scope = user_scope_fixture()
    video = tmp_file("clip.mp4", "videodata")
    srt = tmp_file("clip.srt", "GPS(N) 1.0\n")

    {:ok, flight} =
      Flights.create_flight(scope, %{"name" => "Off"}, %{video: video, srt: srt})

    conn =
      get(conn, ~p"/api/streams/vod/#{flight.id}/metadata/srt", %{"key" => flight.stream_key})

    assert response(conn, 403)
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
