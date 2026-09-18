defmodule DroneFeedWeb.SessionCookie do
  @moduledoc """
  Shared session / remember-me cookie options.

  For cross-origin iframe embeds (research tools), set
  `SESSION_SAME_SITE=None` (or `EMBED_COOKIES=true`). Browsers require
  `Secure` when SameSite is None — always enabled in that mode.
  """

  @doc """
  Options for `Plug.Session` and LiveView socket `connect_info`.
  """
  def session_options do
    [
      store: :cookie,
      key: "_drone_feed_key",
      signing_salt: "KTmKCYQz",
      same_site: same_site(),
      secure: secure?()
    ]
  end

  @doc """
  Options for the signed remember-me cookie.
  """
  def remember_me_options(max_age_seconds) when is_integer(max_age_seconds) do
    [
      sign: true,
      max_age: max_age_seconds,
      same_site: same_site(),
      secure: secure?()
    ]
  end

  defp same_site do
    Application.get_env(:drone_feed, :session_same_site, "Lax")
  end

  defp secure? do
    Application.get_env(:drone_feed, :session_cookie_secure, false) or
      same_site() == "None"
  end
end
