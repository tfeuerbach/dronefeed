defmodule DroneFeedWeb.Api.V1.FlightsController do
  use DroneFeedWeb, :controller

  alias DroneFeed.Flights
  alias DroneFeedWeb.Api.V1.JSON

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    data = Enum.map(Flights.list_flights(scope), &JSON.flight(&1, scope))
    json(conn, %{data: data})
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    try do
      flight = Flights.get_flight!(scope, id)
      json(conn, %{data: JSON.flight(flight, scope)})
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Flight not found or expired"})
    end
  end
end
