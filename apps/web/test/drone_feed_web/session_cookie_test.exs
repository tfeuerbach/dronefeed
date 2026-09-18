defmodule DroneFeedWeb.SessionCookieTest do
  use ExUnit.Case, async: false

  alias DroneFeedWeb.SessionCookie

  setup do
    previous_site = Application.get_env(:drone_feed, :session_same_site)
    previous_secure = Application.get_env(:drone_feed, :session_cookie_secure)

    on_exit(fn ->
      Application.put_env(:drone_feed, :session_same_site, previous_site)
      Application.put_env(:drone_feed, :session_cookie_secure, previous_secure)
    end)

    :ok
  end

  test "defaults to Lax without forcing secure" do
    Application.put_env(:drone_feed, :session_same_site, "Lax")
    Application.put_env(:drone_feed, :session_cookie_secure, false)

    opts = SessionCookie.session_options()
    assert opts[:same_site] == "Lax"
    assert opts[:secure] == false
  end

  test "None forces secure cookies" do
    Application.put_env(:drone_feed, :session_same_site, "None")
    Application.put_env(:drone_feed, :session_cookie_secure, false)

    opts = SessionCookie.session_options()
    assert opts[:same_site] == "None"
    assert opts[:secure] == true

    remember = SessionCookie.remember_me_options(60)
    assert remember[:same_site] == "None"
    assert remember[:secure] == true
  end
end
