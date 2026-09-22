defmodule DroneFeedWeb.Api.V1.FeedsController do
  use DroneFeedWeb, :controller

  alias DroneFeed.Flights
  alias DroneFeed.Streaming
  alias DroneFeedWeb.Api.V1.JSON

  @doc """
  Public feeds currently available to pull (published recordings + live sessions).
  """
  def index(conn, _params) do
    scope = conn.assigns.current_scope

    flights =
      scope
      |> Flights.list_published_flights()
      |> Enum.map(&JSON.flight(&1, scope))

    live =
      scope
      |> Streaming.list_published_live_sessions()
      |> Enum.map(&JSON.live_session(&1, scope))

    json(conn, %{
      data: %{
        flights: flights,
        live: live
      }
    })
  end
end
