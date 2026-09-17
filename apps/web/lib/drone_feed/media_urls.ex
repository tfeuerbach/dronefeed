defmodule DroneFeed.MediaURLs do
  @moduledoc """
  RTMP/RTSP publish and pull URLs, plus HTTP metadata URLs for SRT/KLV sidecars.
  """

  def stream_path(:vod, id), do: "vod/#{id}"
  def stream_path(:live, id), do: "live/#{id}"

  @doc "Public pull host (MEDIA_IP, else MEDIA_HOST)."
  def media_ip do
    Application.get_env(:drone_feed, :media_ip) ||
      Application.fetch_env!(:drone_feed, :media_host)
  end

  @doc """
  Optional DNS hostname for pull URLs. Nil when unset or same as `media_ip/0`.
  """
  def media_domain do
    host = Application.get_env(:drone_feed, :media_host)

    cond do
      not is_binary(host) or host == "" -> nil
      host == media_ip() -> nil
      true -> host
    end
  end

  def rtmp_url(kind, id, opts \\ []) do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, rtmp_port())
    include_key = Keyword.get(opts, :include_key, false)
    stream_key = Keyword.get(opts, :stream_key)

    if include_key && stream_key do
      "rtmp://drone:#{stream_key}@#{host}:#{port}/#{stream_path(kind, id)}"
    else
      "rtmp://#{host}:#{port}/#{stream_path(kind, id)}"
    end
  end

  def rtsp_url(kind, id, opts \\ []) do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, rtsp_port())
    include_key = Keyword.get(opts, :include_key, false)
    stream_key = Keyword.get(opts, :stream_key)

    path = stream_path(kind, id)

    if include_key && stream_key do
      "rtsp://drone:#{stream_key}@#{host}:#{port}/#{path}"
    else
      "rtsp://#{host}:#{port}/#{path}"
    end
  end

  def publish_target(:rtmp, kind, id, stream_key) do
    base = Application.fetch_env!(:drone_feed, :mediamtx_rtmp_url)
    "#{base}/#{stream_path(kind, id)}?user=drone&pass=#{URI.encode_www_form(stream_key)}"
  end

  def publish_target(:rtsp, kind, id, stream_key) do
    base = Application.fetch_env!(:drone_feed, :mediamtx_rtsp_url)
    "rtsp://drone:#{URI.encode_www_form(stream_key)}@#{rtsp_authority(base)}/#{stream_path(kind, id)}"
  end

  # Back-compat
  def publish_target(kind, id, stream_key), do: publish_target(:rtmp, kind, id, stream_key)

  defp rtsp_authority("rtsp://" <> rest), do: rest
  defp rtsp_authority("rtsps://" <> rest), do: rest
  defp rtsp_authority(other) when is_binary(other), do: other

  def metadata_url(flight_id, kind, stream_key, opts \\ []) when kind in ["srt", "klv"] do
    host = Keyword.get(opts, :host, web_host())
    port = Keyword.get(opts, :port, web_port())
    scheme = Keyword.get(opts, :scheme, web_scheme())

    "#{scheme}://#{host}:#{port}/api/streams/vod/#{flight_id}/metadata/#{kind}?key=#{URI.encode_www_form(stream_key)}"
  end

  defp rtmp_port, do: Application.fetch_env!(:drone_feed, :rtmp_port)
  defp rtsp_port, do: Application.fetch_env!(:drone_feed, :rtsp_port)

  defp web_host do
    Application.get_env(:drone_feed, :web_host) || media_domain() || media_ip()
  end

  defp web_port do
    Application.get_env(:drone_feed, :web_port) ||
      String.to_integer(System.get_env("PORT") || "4000")
  end

  defp web_scheme do
    Application.get_env(:drone_feed, :web_scheme) || "http"
  end
end
