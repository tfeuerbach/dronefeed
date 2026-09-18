defmodule DroneFeedWeb.Plugs.FrameHeaders do
  @moduledoc """
  Allows DroneFeed to be embedded in research-tool iframes.

  Set `FRAME_ANCESTORS` (e.g. `*` or `https://gladius.example.com`) to emit
  `Content-Security-Policy: frame-ancestors …` and clear `X-Frame-Options`.
  When unset, Phoenix default secure headers apply (typically deny framing).
  """

  @behaviour Plug

  import Plug.Conn

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Application.get_env(:drone_feed, :frame_ancestors) do
      nil ->
        conn

      "" ->
        conn

      ancestors when is_binary(ancestors) ->
        conn
        |> delete_resp_header("x-frame-options")
        |> put_resp_header("content-security-policy", "frame-ancestors #{ancestors}")
    end
  end
end
