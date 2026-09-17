defmodule DroneFeedWeb.MediaAuthController do
  use DroneFeedWeb, :controller

  alias DroneFeed.Streaming.MediaAuth

  def auth(conn, params) do
    payload = normalize(params)

    case MediaAuth.authorize(payload) do
      :ok ->
        send_resp(conn, 200, "ok")

      {:error, :unauthorized} ->
        send_resp(conn, 401, "unauthorized")

      {:error, _} ->
        send_resp(conn, 403, "forbidden")
    end
  end

  defp normalize(params) when is_map(params) do
    Map.merge(params, Map.get(params, "_json") || %{})
  end
end
