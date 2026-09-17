defmodule DroneFeed.Streaming.FlightLogTest do
  use ExUnit.Case, async: false

  alias DroneFeed.Streaming.FlightLog

  setup do
    id = Ecto.UUID.generate()
    FlightLog.clear(id)
    %{id: id}
  end

  test "append list and clear", %{id: id} do
    FlightLog.info(id, :auth, "ALLOWED read via rtsp from 1.2.3.4")
    FlightLog.error(id, :ffmpeg_rtsp, "Connection refused")

    entries = FlightLog.list(id)
    assert length(entries) == 2
    assert List.last(entries).level == :error

    assert length(FlightLog.list(id, min_level: :warn)) == 1

    FlightLog.clear(id)
    assert FlightLog.list(id) == []
  end

  test "broadcasts on append", %{id: id} do
    Phoenix.PubSub.subscribe(DroneFeed.PubSub, FlightLog.topic(id))
    FlightLog.warn(id, :auth, "DENIED")
    assert_receive {:flight_log, %{level: :warn, source: "auth"}}
  end
end
