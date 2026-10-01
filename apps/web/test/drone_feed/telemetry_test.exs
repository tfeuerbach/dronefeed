defmodule DroneFeed.TelemetryTest do
  use ExUnit.Case, async: true

  alias DroneFeed.Telemetry

  @srt """
  1
  00:00:01,000 --> 00:00:01,033
  [latitude: 1.5] [longitude: 2.5] [altitude: 10.0]

  2
  00:00:02,500 --> 00:00:02,533
  [latitude: 1.6] [longitude: 2.6] [altitude: 11.5]
  """

  @dji_srt """
  40
  00:00:01,301 --> 00:00:01,334
  <font size="36">SrtCnt : 40, DiffTime : 33ms
  2023-01-13 12:52:03,349,060
  [iso : 100] [shutter : 1/2000.0] [fnum : 280] [ev : 0] [ct : 5028] [color_md : default] [focal_len : 224] [dzoom_ratio: 10000, delta:0],[latitude: 0.410171] [longitude: 36.863118] [altitude: 35.400000]
  </font>
  """

  test "parse_srt extracts timed geo samples" do
    points = Telemetry.parse_srt(@srt)

    assert length(points) == 2
    assert hd(points).t_ms == 1000
    assert hd(points).lat == 1.5
    assert hd(points).lon == 2.5
    assert hd(points).alt == 10.0
    assert List.last(points).t_ms == 2500
    assert List.last(points).alt == 11.5
  end

  test "parse_srt formats DJI cues without SRT/HTML fluff" do
    [point] = Telemetry.parse_srt(@dji_srt)

    assert point.t_ms == 1301
    assert point.lat == 0.410171
    assert point.lon == 36.863118
    assert point.alt == 35.4

    assert point.raw =~ "t 00:00:01.301"
    assert point.raw =~ "#40"
    assert point.raw =~ "Δ 33ms"
    assert point.raw =~ "2023-01-13 12:52:03.349060"
    assert point.raw =~ "ISO 100"
    assert point.raw =~ "f/2.80"
    assert point.raw =~ "5028K"
    assert point.raw =~ "22.4 mm"
    assert point.raw =~ "zoom 1.00×"
    assert point.raw =~ "0.410171, 36.863118"
    assert point.raw =~ "35.4 m"

    refute point.raw =~ "<font"
    refute point.raw =~ "-->"
    refute point.raw =~ "SrtCnt"
  end

  @embedded_gps """
  1
  00:00:00,000 --> 00:00:01,000
  F/2.8, SS 781.10, ISO 100, EV 0, DZOOM 2.000, GPS (-79.3895, 35.4445, 27), D 1.97m, H 16.30m, H.S 0.00m/s, V.S -0.00m/s

  2
  00:00:01,000 --> 00:00:02,000
  F/2.8, SS 781.10, ISO 100, EV 0, DZOOM 2.000, GPS (-79.3896, 35.4446, 26.5), D 1.97m, H 16.30m, H.S 0.00m/s, V.S -0.00m/s
  """

  test "parse_srt reads muxed DJI GPS tuples as longitude, latitude, altitude" do
    [first, second] = Telemetry.parse_srt(@embedded_gps)

    assert first.t_ms == 0
    assert first.lat == 35.4445
    assert first.lon == -79.3895
    assert first.alt == 27.0
    assert first.raw =~ "ISO 100"
    assert first.raw =~ "DZOOM 2.000"
    assert first.raw =~ "35.444500, -79.389500"
    assert first.raw =~ "27.0 m"

    assert second.t_ms == 1000
    assert second.lat == 35.4446
    assert second.lon == -79.3896
    assert second.alt == 26.5
  end
end
