defmodule DroneFeedWeb.SessionCookie do
  @moduledoc """
  Shared session / remember-me cookie options.

  For cross-origin iframe embeds (research tools), set
  `SESSION_SAME_SITE=None` (or `EMBED_COOKIES=true`). Browsers require
  `Secure` when SameSite is None — always enabled in that mode.

  Chrome's third-party cookie phaseout also requires the `Partitioned`
  attribute (CHIPS) for cookies set inside cross-site iframes; without it
  the session cookie is dropped, LiveView reconnects in a loop, and form
  focus is lost on every remount.
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
    |> maybe_partitioned()
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
    |> maybe_partitioned()
  end

  defp same_site do
    Application.get_env(:drone_feed, :session_same_site, "Lax")
  end

  defp secure? do
    Application.get_env(:drone_feed, :session_cookie_secure, false) or
      same_site() == "None"
  end

  # Plug has no first-class :partitioned yet — append via :extra.
  defp maybe_partitioned(opts) do
    if same_site() == "None" do
      Keyword.put(opts, :extra, "Partitioned;")
    else
      opts
    end
  end
end
