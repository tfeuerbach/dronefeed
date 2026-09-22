defmodule DroneFeed.Flights.SlugTest do
  use DroneFeed.DataCase

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Flights
  alias DroneFeed.Flights.Slug

  test "from_name slugifies display names" do
    assert Slug.from_name("Cheyenne Feed 2") == "cheyenne-feed-2"
    assert Slug.from_name("  Esri_multiplexer_0.mp4 ") == "esri-multiplexer-0-mp4"
    assert Slug.from_name("!!!") == "flight"
  end

  test "unique appends suffix on collision" do
    {:ok, user} = Accounts.register_user(%{email: "slug@example.com", status: "active"})
    scope = Scope.for_user(user)
    video = tmp_file("a.mp4", "videodata")

    assert {:ok, first} =
             Flights.create_flight(scope, %{"name" => "Cheyenne Feed 2"}, %{video: video})

    assert first.slug == "cheyenne-feed-2"

    video2 = tmp_file("b.mp4", "videodata")

    assert {:ok, second} =
             Flights.create_flight(scope, %{"name" => "Cheyenne Feed 2"}, %{video: video2})

    assert second.slug == "cheyenne-feed-2-2"
  end

  test "get_flight! resolves slug and uuid" do
    {:ok, user} = Accounts.register_user(%{email: "lookup@example.com", status: "active"})
    scope = Scope.for_user(user)
    video = tmp_file("c.mp4", "videodata")

    assert {:ok, flight} =
             Flights.create_flight(scope, %{"name" => "Truck Run"}, %{video: video})

    assert Flights.get_flight!(scope, flight.slug).id == flight.id
    assert Flights.get_flight!(scope, flight.id).id == flight.id
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
