defmodule DroneFeed.Flights.BrowserPreviewTest do
  use ExUnit.Case, async: true

  alias DroneFeed.Flights.BrowserPreview

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
end
