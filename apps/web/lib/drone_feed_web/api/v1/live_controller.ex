defmodule DroneFeedWeb.Api.V1.LiveController do
  use DroneFeedWeb, :controller

  alias DroneFeed.Streaming
  alias DroneFeedWeb.Api.V1.JSON

  def index(conn, _params) do
    scope = conn.assigns.current_scope
    data = Enum.map(Streaming.list_live_sessions(scope), &JSON.live_session(&1, scope))
    json(conn, %{data: data})
  end

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope

    case Streaming.fetch_active_live_session(scope, id) do
      {:ok, session} ->
        json(conn, %{data: JSON.live_session(session, scope)})

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "not_found", message: "Live session not found or inactive"})
    end
  end
end
