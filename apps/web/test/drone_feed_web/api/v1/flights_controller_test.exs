defmodule DroneFeedWeb.Api.V1.FlightsControllerTest do
  use DroneFeedWeb.ConnCase, async: true

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope
  alias DroneFeed.AccountsFixtures
  alias DroneFeed.Flights

  setup %{conn: conn} do
    user = AccountsFixtures.user_fixture(%{email: "api-pilot@example.com"})
    {:ok, token} = Accounts.create_api_token(user, %{name: "test"})
    scope = Scope.for_user(user)

    video = tmp_file("clip.mp4", "fake-video")
    {:ok, flight} = Flights.create_flight(scope, %{"name" => "Sortie API"}, %{video: video})

    %{
      conn: conn,
      user: user,
      plaintext: token.plaintext,
      scope: scope,
      flight: flight
    }
  end

  test "requires a token", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/flights")
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "lists flights with Bearer token", %{conn: conn, plaintext: plaintext, flight: flight} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get(~p"/api/v1/flights")

    assert %{"data" => data} = json_response(conn, 200)
    assert Enum.any?(data, &(&1["id"] == flight.id))
    item = Enum.find(data, &(&1["id"] == flight.id))
    assert item["name"] == "Sortie API"
    assert item["slug"] == "sortie-api"
    assert item["publishing"] == false
    assert item["urls"] == nil
  end

  test "accepts X-Api-Key", %{conn: conn, plaintext: plaintext} do
    conn =
      conn
      |> put_req_header("x-api-key", plaintext)
      |> get(~p"/api/v1/me")

    assert %{"data" => %{"email" => "api-pilot@example.com"}} = json_response(conn, 200)
  end

  test "feeds endpoint returns published shape", %{conn: conn, plaintext: plaintext} do
    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get(~p"/api/v1/feeds")

    assert %{"data" => %{"flights" => flights, "live" => live}} = json_response(conn, 200)
    assert is_list(flights)
    assert is_list(live)
  end

  test "show flight by id or slug", %{conn: conn, plaintext: plaintext, flight: flight} do
    by_id =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get(~p"/api/v1/flights/#{flight.id}")

    assert %{"data" => %{"id" => id, "slug" => "sortie-api", "type" => "flight"}} =
             json_response(by_id, 200)

    assert id == flight.id

    by_slug =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get(~p"/api/v1/flights/#{flight.slug}")

    assert json_response(by_slug, 200)["data"]["id"] == flight.id
  end

  test "includes pull urls when publishing", %{
    conn: conn,
    plaintext: plaintext,
    scope: scope,
    flight: flight
  } do
    {:ok, _} = Flights.set_publishing(scope, flight.id, true)

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> get(~p"/api/v1/flights/#{flight.id}")

    assert %{"data" => %{"urls" => urls}} = json_response(conn, 200)
    assert is_binary(urls["srt_pull"])
    assert is_binary(urls["primary_pull"])
  end

  defp tmp_file(name, contents) do
    path = Path.join(System.tmp_dir!(), "#{System.unique_integer([:positive])}-#{name}")
    File.write!(path, contents)
    %{path: path, filename: name}
  end
end
