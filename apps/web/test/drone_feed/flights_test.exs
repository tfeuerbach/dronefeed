defmodule DroneFeed.FlightsTest do
  use DroneFeed.DataCase

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Flights

  setup do
    {:ok, user} =
      Accounts.register_user(%{email: "pilot@example.com", status: "active"})

    %{scope: Scope.for_user(user)}
  end

  test "create_flight stores files and sets 5-day expiry", %{scope: scope} do
    video = tmp_file("flight.mp4", "videodata")
    srt = tmp_file("flight.srt", "1\n00:00:00,000 --> 00:00:01,000\nhello\n")

    assert {:ok, flight} =
             Flights.create_flight(scope, %{"name" => "Sortie A"}, %{video: video, srt: srt})

    assert flight.name == "Sortie A"
    assert flight.publishing == false
    assert File.exists?(flight.video_path)
    assert File.exists?(flight.srt_path)
    assert DateTime.diff(flight.expires_at, DateTime.utc_now(), :day) in 4..5
  end

  test "set_publishing toggles flag", %{scope: scope} do
    video = tmp_file("flight.mp4", "videodata")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Sortie B"}, %{video: video})
    {:ok, on} = Flights.set_publishing(scope, flight.id, true)
    assert on.publishing
    {:ok, off} = Flights.set_publishing(scope, flight.id, false)
    refute off.publishing
  end

  test "list_flights is shared across users", %{scope: scope} do
    video = tmp_file("shared.mp4", "videodata")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Shared"}, %{video: video})

    {:ok, other} = Accounts.register_user(%{email: "viewer@example.com", status: "active"})
    other_scope = Scope.for_user(other)

    ids = other_scope |> Flights.list_flights() |> Enum.map(& &1.id)
    assert flight.id in ids
    assert Flights.get_flight!(other_scope, flight.id).id == flight.id
    assert {:error, :forbidden} = Flights.set_publishing(other_scope, flight.id, true)
  end

  test "list_published_flights only includes publishing feeds", %{scope: scope} do
    video = tmp_file("pub.mp4", "videodata")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Pub"}, %{video: video})
    assert Flights.list_published_flights(scope) == []

    {:ok, _} = Flights.set_publishing(scope, flight.id, true)
    assert Enum.map(Flights.list_published_flights(scope), & &1.id) == [flight.id]
  end

  test "uploader and admin can delete; other users cannot", %{scope: scope} do
    video = tmp_file("del.mp4", "videodata")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Delete me"}, %{video: video})

    {:ok, other} = Accounts.register_user(%{email: "other@example.com", status: "active"})
    other_scope = Scope.for_user(other)
    refute Flights.can_delete?(other_scope, flight)
    assert {:error, :forbidden} = Flights.delete_flight(other_scope, flight.id)

    admin = DroneFeed.AccountsFixtures.admin_fixture()
    admin_scope = Scope.for_user(admin)
    assert Flights.can_delete?(admin_scope, flight)
    assert Flights.can_delete?(scope, flight)

    assert {:ok, _} = Flights.delete_flight(admin_scope, flight.id)
    assert_raise Ecto.NoResultsError, fn -> Flights.get_flight!(scope, flight.id) end
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
