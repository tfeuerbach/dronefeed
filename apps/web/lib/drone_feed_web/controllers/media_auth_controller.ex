defmodule DroneFeedWeb.MediaAuthController do
  use DroneFeedWeb, :controller

  alias DroneFeed.Streaming.MediaAuth

  @doc """
  MediaMTX HTTP authentication hook.
  200 = allow, 401 = challenge (empty RTSP probe), 403 = deny.
  """
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
    # MediaMTX sends JSON body; Plug may already decode to string keys.
    # Also accept nested under "_json" depending on content type.
    Map.merge(params, Map.get(params, "_json") || %{})
  end
end
