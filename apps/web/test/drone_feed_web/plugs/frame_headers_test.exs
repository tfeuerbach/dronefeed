defmodule DroneFeedWeb.Plugs.FrameHeadersTest do
  use DroneFeedWeb.ConnCase, async: true

  alias DroneFeedWeb.Plugs.FrameHeaders

  setup do
    previous = Application.get_env(:drone_feed, :frame_ancestors)

    on_exit(fn ->
      Application.put_env(:drone_feed, :frame_ancestors, previous)
    end)

    :ok
  end

  test "leaves headers alone when frame_ancestors unset", %{conn: conn} do
    Application.put_env(:drone_feed, :frame_ancestors, nil)

    conn =
      conn
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
      |> FrameHeaders.call([])

    assert get_resp_header(conn, "x-frame-options") == ["SAMEORIGIN"]
    assert get_resp_header(conn, "content-security-policy") == []
  end

  test "allows framing when frame_ancestors set", %{conn: conn} do
    Application.put_env(:drone_feed, :frame_ancestors, "*")

    conn =
      conn
      |> put_resp_header("x-frame-options", "SAMEORIGIN")
      |> FrameHeaders.call([])

    assert get_resp_header(conn, "x-frame-options") == []
    assert get_resp_header(conn, "content-security-policy") == ["frame-ancestors *"]
  end
end
