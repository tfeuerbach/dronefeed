defmodule DroneFeed.StreamingTest do
  use DroneFeed.DataCase, async: true

  alias DroneFeed.Streaming

  setup do
    %{scope: DroneFeed.AccountsFixtures.user_scope_fixture()}
  end

  test "creates push live session by default", %{scope: scope} do
    assert {:ok, session} = Streaming.create_live_session(scope, %{"name" => "Pad"})
    assert session.ingest_mode == "push"
    assert is_nil(session.udp_port)
    urls = Streaming.urls(session)
    assert urls.rtmp_ingest =~ "rtmp://"
    assert is_nil(urls.udp_ingest)
  end

  test "creates udp_mpegts session with allocated port", %{scope: scope} do
    assert {:ok, session} =
             Streaming.create_live_session(scope, %{
               "name" => "Drone UDP",
               "ingest_mode" => "udp_mpegts"
             })

    assert session.ingest_mode == "udp_mpegts"
    assert session.udp_port in 8900..8905

    urls = Streaming.urls(session)
    assert urls.udp_ingest == "udp://127.0.0.1:#{session.udp_port}"
    assert is_nil(urls.rtmp_ingest)
    assert urls.rtsp_pull =~ "rtsp://"
  end

  test "allocates distinct udp ports and frees on end", %{scope: scope} do
    assert {:ok, a} =
             Streaming.create_live_session(scope, %{"name" => "A", "ingest_mode" => "udp_mpegts"})

    assert {:ok, b} =
             Streaming.create_live_session(scope, %{"name" => "B", "ingest_mode" => "udp_mpegts"})

    assert a.udp_port != b.udp_port

    assert {:ok, ended} = Streaming.end_live_session(scope, a.id)
    assert ended.active == false
    assert is_nil(ended.udp_port)

    assert {:ok, c} =
             Streaming.create_live_session(scope, %{"name" => "C", "ingest_mode" => "udp_mpegts"})

    assert c.udp_port == a.udp_port
  end
end
