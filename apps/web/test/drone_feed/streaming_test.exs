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
    assert urls.rtmp_ingest =~ "?user=drone&pass="
    assert urls.rtmp_ingest =~ session.stream_key
    assert urls.rtmp_dji_server =~ "rtmp://"
    assert urls.rtmp_dji_server =~ "/live"
    assert urls.rtmp_dji_key == "#{session.id}?user=drone&pass=#{URI.encode_www_form(session.stream_key)}"
    assert urls.rtmp_pull =~ "?user=drone&pass=#{URI.encode_www_form(session.stream_key)}"
    assert urls.hls_pull =~ "/hls/live/#{session.id}/index.m3u8"
    assert urls.rtsp_pull =~ "rtsp://drone:#{session.stream_key}@"
    assert urls.srt_pull =~ ":drone:#{session.stream_key}"
    assert urls.srt_pull =~ "&latency=4000"
    refute urls.srt_pull =~ "pkt_size"
    refute urls.srt_pull =~ "rcvbuf"
    refute Map.has_key?(urls, :stream_key)
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
    assert urls.rtsp_pull =~ "rtsp://drone:#{session.stream_key}@"
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

  test "lists active sessions globally and restricts end to owner", %{scope: scope} do
    other = DroneFeed.AccountsFixtures.user_scope_fixture()

    assert {:ok, mine} = Streaming.create_live_session(scope, %{"name" => "Mine"})
    assert {:ok, theirs} = Streaming.create_live_session(other, %{"name" => "Theirs"})

    ids = Streaming.list_live_sessions(scope) |> Enum.map(& &1.id)
    assert mine.id in ids
    assert theirs.id in ids

    assert Streaming.owns?(scope, mine)
    refute Streaming.owns?(scope, theirs)
    refute Streaming.can_end?(scope, theirs)

    assert {:error, :forbidden} = Streaming.end_live_session(scope, theirs.id)

    admin_scope = DroneFeed.AccountsFixtures.user_scope_fixture(DroneFeed.AccountsFixtures.admin_fixture())
    assert Streaming.can_end?(admin_scope, theirs)
    assert {:ok, _} = Streaming.end_live_session(admin_scope, theirs.id)
  end

  test "fetch_active_live_session finds shared active sessions", %{scope: scope} do
    other = DroneFeed.AccountsFixtures.user_scope_fixture()
    assert {:ok, theirs} = Streaming.create_live_session(other, %{"name" => "Shared"})

    assert {:ok, found} = Streaming.fetch_active_live_session(scope, theirs.id)
    assert found.id == theirs.id

    assert {:ok, _} = Streaming.end_live_session(other, theirs.id)
    assert {:error, :not_found} = Streaming.fetch_active_live_session(scope, theirs.id)
  end
end
