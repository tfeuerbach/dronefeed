defmodule DroneFeed.Streaming.MediaAuthTest do
  use DroneFeed.DataCase

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Flights
  alias DroneFeed.Streaming
  alias DroneFeed.Streaming.MediaAuth

  setup do
    {:ok, user} = Accounts.register_user(%{email: "researcher@example.com", status: "active"})
    scope = Scope.for_user(user)
    %{scope: scope, user: user}
  end

  test "rejects empty credentials with unauthorized", _ do
    assert {:error, :unauthorized} =
             MediaAuth.authorize(%{"action" => "read", "path" => "vod/x", "user" => "", "password" => ""})
  end

  test "allows read/publish for publishing flight with stream key", %{scope: scope} do
    video = tmp_file("clip.mp4", "fake")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Test"}, %{video: video})
    {:ok, flight} = Flights.set_publishing(scope, flight.id, true)

    assert :ok =
             MediaAuth.authorize(%{
               "action" => "read",
               "path" => "vod/#{flight.id}",
               "user" => "drone",
               "password" => flight.stream_key
             })

    assert :ok =
             MediaAuth.authorize(%{
               "action" => "publish",
               "path" => "vod/#{flight.id}",
               "user" => "drone",
               "password" => flight.stream_key
             })

    assert {:error, :forbidden} =
             MediaAuth.authorize(%{
               "action" => "read",
               "path" => "vod/#{flight.id}",
               "user" => "drone",
               "password" => "wrong"
             })
  end

  test "denies vod when not publishing", %{scope: scope} do
    video = tmp_file("clip.mp4", "fake")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Off"}, %{video: video})

    assert {:error, :forbidden} =
             MediaAuth.authorize(%{
               "action" => "read",
               "path" => "vod/#{flight.id}",
               "user" => "drone",
               "password" => flight.stream_key
             })
  end

  test "allows active live session", %{scope: scope} do
    {:ok, session} = Streaming.create_live_session(scope, %{"name" => "Pad 1"})

    assert :ok =
             MediaAuth.authorize(%{
               "action" => "publish",
               "path" => "live/#{session.id}",
               "user" => "drone",
               "password" => session.stream_key
             })

    {:ok, _} = Streaming.end_live_session(scope, session.id)

    assert {:error, :forbidden} =
             MediaAuth.authorize(%{
               "action" => "publish",
               "path" => "live/#{session.id}",
               "user" => "drone",
               "password" => session.stream_key
             })
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
