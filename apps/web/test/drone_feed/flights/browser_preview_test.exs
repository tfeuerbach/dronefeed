defmodule DroneFeed.Flights.BrowserPreviewTest do
  use ExUnit.Case, async: true

  alias DroneFeed.Flights.BrowserPreview
  alias DroneFeed.Flights.Flight

  test "real MP4 + H.264 is browser-playable" do
    assert BrowserPreview.browser_playable_probe?(%{
             codec: "h264",
             format: "mov,mp4,m4a,3gp,3g2,mj2"
           })
  end

  test "MPEG-TS labeled as mp4 is not browser-playable" do
    refute BrowserPreview.browser_playable_probe?(%{
             codec: "h264",
             format: "mpegts"
           })
  end

  test "mpeg2video is not browser-playable even in mp4 tokens" do
    refute BrowserPreview.browser_playable_probe?(%{
             codec: "mpeg2video",
             format: "mov,mp4,m4a,3gp,3g2,mj2"
           })
  end

  test "webm + vp9 is browser-playable" do
    assert BrowserPreview.browser_playable_probe?(%{
             codec: "vp9",
             format: "matroska,webm"
           })
  end

  test "ready? clears abandoned lock when preview already exists" do
    dir = Path.join(System.tmp_dir!(), "drone_feed_preview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    source = Path.join(dir, "video.mp4")
    preview = Path.join(dir, "preview.mp4")
    lock = preview <> ".lock"

    File.write!(source, "source")
    Process.sleep(1100)
    File.write!(preview, "preview")
    File.write!(lock, "")
    File.touch!(lock, {{2020, 1, 1}, {0, 0, 0}})

    flight = %Flight{video_path: source}
    assert BrowserPreview.ready?(flight)
    refute File.exists?(lock)
  end

  test "ready? removes empty preview left without a lock" do
    dir = Path.join(System.tmp_dir!(), "drone_feed_preview_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    source = Path.join(dir, "video.mp4")
    preview = Path.join(dir, "preview.mp4")

    File.write!(source, "source")
    File.write!(preview, "")

    flight = %Flight{video_path: source}
    refute BrowserPreview.ready?(flight)
    refute File.exists?(preview)
  end
end
