defmodule DroneFeed.Streaming.PublisherTest do
  use ExUnit.Case, async: true

  alias DroneFeed.Flights.Flight
  alias DroneFeed.Streaming.Publisher

  test "public feed ffmpeg args are live-style encode (not -c copy)" do
    flight = %Flight{
      id: Ecto.UUID.generate(),
      stream_key: "test-key"
    }

    args = Publisher.mpegts_srt_args(flight, "/tmp/publish_stanag.ts")
    joined = Enum.join(args, " ")

    assert "-c:v" in args
    assert "libx264" in args
    assert "-profile:v" in args
    assert "main" in args
    assert "-g" in args
    assert "30" in args
    assert "-bf" in args
    assert "0" in args
    assert "-vf" in args
    assert "scale=-2:1080" in args
    assert "-c:d" in args
    assert "copy" in args
    assert "-map" in args
    assert "0:v:0" in args
    assert "0:d:0?" in args

    refute joined =~ ~r/(^|\s)-c(\s|$)/
    refute "-c" in args and Enum.at(args, Enum.find_index(args, &(&1 == "-c")) + 1) == "copy"
    # Ensure we did not request a full-stream copy publish.
    refute Enum.any?(Enum.chunk_every(args, 2, 1, :discard), fn
             ["-c", "copy"] -> true
             _ -> false
           end)

    assert Enum.any?(args, &String.starts_with?(&1, "srt://"))
    assert Enum.any?(args, &String.contains?(&1, "latency=4000000"))
  end
end
