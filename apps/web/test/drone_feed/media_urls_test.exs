defmodule DroneFeed.MediaURLsTest do
  use ExUnit.Case, async: true

  alias DroneFeed.MediaURLs

  test "public SRT pull URL is Haivision-style (ms latency, no ffmpeg extras)" do
    id = Ecto.UUID.generate()
    key = "test-stream-key"

    url =
      MediaURLs.srt_mpegts_url(:vod, id,
        host: "203.0.113.10",
        include_key: true,
        stream_key: key
      )

    assert url ==
             "srt://203.0.113.10:8890?streamid=read:vod/#{id}:drone:#{key}&latency=4000"

    assert url =~ "latency=4000"
    refute url =~ "4000000"
    refute url =~ "pkt_size"
    refute url =~ "rcvbuf"
    refute url =~ "sndbuf"

    live =
      MediaURLs.srt_mpegts_url(:live, id,
        host: "203.0.113.10",
        include_key: true,
        stream_key: key
      )

    assert live ==
             "srt://203.0.113.10:8890?streamid=read:live/#{id}:drone:#{key}&latency=4000"
  end

  test "internal ffmpeg publish URL keeps pkt_size (not the public pull shape)" do
    id = Ecto.UUID.generate()
    key = "pub-key"
    url = MediaURLs.publish_srt_mpegts_url(:vod, id, key)

    assert url =~ "streamid=publish:vod/#{id}:drone:#{key}"
    assert url =~ "pkt_size=1316"
    refute url =~ "latency=4000"
  end
end
