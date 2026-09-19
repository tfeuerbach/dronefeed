defmodule DroneFeed.MediaURLs do
  @moduledoc """
  Capability URLs for MediaMTX pull/publish and HTTP metadata sidecars.

  Pull URLs embed the stream token (no separate username/password for clients).
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

    # MediaMTX RTMP auth is query-only (`?user=&pass=`). URL userinfo is ignored.
    if include_key && is_binary(stream_key) and stream_key != "" do
      rtmp_url_query(kind, id, stream_key, host: host, port: port)
    else
      "rtmp://#{host}:#{port}/#{stream_path(kind, id)}"
    end
  end

  @doc """
  RTMP publish/pull URL with token in the query string.

  Required for MediaMTX RTMP auth and for DJI Fly / GO **Custom RTMP**.
  Video/audio only (no telemetry / KLV).
  """
  def rtmp_url_query(kind, id, stream_key, opts \\ [])
      when kind in [:vod, :live] and is_binary(stream_key) do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, rtmp_port())

    "rtmp://#{host}:#{port}/#{stream_path(kind, id)}?user=drone&pass=#{URI.encode_www_form(stream_key)}"
  end

  @doc """
  DJI-style two-field Custom Livestream: server URL + stream key.

  The app joins them as `server/key`, producing
  `rtmp://host:1935/live/<id>?user=drone&pass=<token>`.
  """
  def rtmp_dji_server(opts \\ []) do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, rtmp_port())
    "rtmp://#{host}:#{port}/live"
  end

  def rtmp_dji_stream_key(id, stream_key)
      when is_binary(id) and is_binary(stream_key) do
    "#{id}?user=drone&pass=#{URI.encode_www_form(stream_key)}"
  end

  @doc """
  Same-origin HLS playlist for the browser UI (proxied by Caddy at `/hls/...`).

  Avoids mixed-content blocks when the app is HTTPS and MediaMTX HLS is plain HTTP.
  Auth via Basic (`drone` / stream key) or `?user=&pass=` — the LiveHlsPreview hook
  sends Basic on each request.
  """
  def hls_browser_url(kind, id, opts \\ []) when kind in [:vod, :live] do
    host = Keyword.get(opts, :host, web_host())
    port = Keyword.get(opts, :port, web_port())
    scheme = Keyword.get(opts, :scheme, web_scheme())
    path = "/hls/#{stream_path(kind, id)}/index.m3u8"

    authority =
      cond do
        scheme == "https" and port in [443, "443"] -> host
        scheme == "http" and port in [80, "80"] -> host
        true -> "#{host}:#{port}"
      end

    "#{scheme}://#{authority}#{path}"
  end

  @doc """
  Direct MediaMTX HLS playlist (`http://MEDIA_IP:8888/...`) for tools / ops.
  """
  def hls_url(kind, id, opts \\ []) when kind in [:vod, :live] do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, hls_port())
    "http://#{host}:#{port}/#{stream_path(kind, id)}/index.m3u8"
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

  @doc """
  Public SRT pull URL for MPEG-TS (H.264 + KLV). Auth via MediaMTX streamid.

  Haivision / MediaMTX (gosrt) URI — `latency` is **milliseconds**.

  Example: `srt://host:8890?streamid=read:vod/<id>:drone:<key>&latency=2000`

  Default ~2s ARQ headroom for WAN research tools. Override with `SRT_PULL_LATENCY_MS`
  (1000 on a clean LAN; 3000–4000 on lossy links).

  Do not put FFmpeg-only query keys here (`pkt_size`, microsecond `latency`,
  `rcvbuf`/`sndbuf`). Internal FFmpeg publish keeps those separately.
  """
  def srt_mpegts_url(kind, id, opts \\ []) do
    host = Keyword.get(opts, :host, media_ip())
    port = Keyword.get(opts, :port, srt_port())
    include_key = Keyword.get(opts, :include_key, false)
    stream_key = Keyword.get(opts, :stream_key)
    path = stream_path(kind, id)
    latency_ms = Keyword.get(opts, :latency_ms, srt_pull_latency_ms())

    streamid =
      if include_key && stream_key do
        "read:#{path}:drone:#{stream_key}"
      else
        "read:#{path}"
      end

    "srt://#{host}:#{port}?streamid=#{streamid}&latency=#{latency_ms}"
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

  @doc """
  Internal SRT publish target (MPEG-TS with KLV) from the web container into MediaMTX.
  """
  def publish_srt_mpegts_url(kind, id, stream_key) when kind in [:vod, :live] do
    host = Application.get_env(:drone_feed, :mediamtx_host, "mediamtx")
    port = Application.get_env(:drone_feed, :srt_port, 8890)
    path = stream_path(kind, id)
    streamid = "publish:#{path}:drone:#{stream_key}"
    "srt://#{host}:#{port}?streamid=#{streamid}&pkt_size=1316"
  end

  @doc """
  Destination for drones / encoders sending MPEG-TS over UDP (unicast).
  """
  def udp_mpegts_url(port, opts \\ []) when is_integer(port) do
    host = Keyword.get(opts, :host, media_ip())
    "udp://#{host}:#{port}"
  end

  @doc """
  Internal publish target from the web container into MediaMTX (MPEG-TS / UDP).
  Used for live drone UDP ingest paths only.
  """
  def publish_udp_mpegts_url(port) when is_integer(port) do
    host = Application.get_env(:drone_feed, :mediamtx_host, "mediamtx")
    "udp://#{host}:#{port}?pkt_size=1316"
  end

  defp rtsp_authority("rtsp://" <> rest), do: rest
  defp rtsp_authority("rtsps://" <> rest), do: rest
  defp rtsp_authority(other) when is_binary(other), do: other

  def metadata_url(flight_id, kind, stream_key, opts \\ []) when kind in ["srt", "klv"] do
    host = Keyword.get(opts, :host, web_host())
    port = Keyword.get(opts, :port, web_port())
    scheme = Keyword.get(opts, :scheme, web_scheme())
    path = "/api/streams/vod/#{flight_id}/metadata/#{kind}?key=#{URI.encode_www_form(stream_key)}"

    authority =
      cond do
        scheme == "https" and port in [443, "443"] -> host
        scheme == "http" and port in [80, "80"] -> host
        true -> "#{host}:#{port}"
      end

    "#{scheme}://#{authority}#{path}"
  end

  defp rtmp_port, do: Application.fetch_env!(:drone_feed, :rtmp_port)
  defp rtsp_port, do: Application.fetch_env!(:drone_feed, :rtsp_port)
  defp srt_port, do: Application.get_env(:drone_feed, :srt_port, 8890)
  defp hls_port, do: Application.get_env(:drone_feed, :hls_port, 8888)

  defp srt_pull_latency_ms do
    Application.get_env(:drone_feed, :srt_pull_latency_ms, 2000)
  end

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
