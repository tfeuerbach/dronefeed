defmodule DroneFeed.Streaming.Publisher do
  @moduledoc """
  Republishes a recorded flight as a live-style MPEG-TS feed for MediaMTX.

  Source assets are normalized via `StanagMux` into `publish_stanag.ts` (full
  quality H.264 + MISB KLV). The Public feed **does not** `-c copy` that file
  into MediaMTX: MediaMTX's SRT/HLS remux of high-bitrate High-profile 4K copy
  often advertises H264 with empty SPS/PPS (`0×0` / unspecified size), so
  Gladius and other HLS clients sit on Connecting forever.

  Instead FFmpeg loops a **distribution encode**: Main (or Baseline) Annex-B
  H.264 with SPS/PPS on IDRs about every 1–2s, default 1080p, and copies the
  KLV data track. MediaMTX re-serves that as SRT/RTSP/RTMP/HLS.
  """

  use GenServer
  require Logger

  alias DroneFeed.Flights.Flight
  alias DroneFeed.MediaURLs
  alias DroneFeed.Streaming.FlightLog
  alias DroneFeed.Streaming.MediaMTX
  alias DroneFeed.Streaming.StanagMux

  def start_link(%Flight{} = flight) do
    GenServer.start_link(__MODULE__, flight, name: via(flight.id))
  end

  def via(flight_id), do: {:via, Registry, {DroneFeed.Streaming.PublisherRegistry, flight_id}}

  def stop(flight_id) do
    case Registry.lookup(DroneFeed.Streaming.PublisherRegistry, flight_id) do
      [{pid, _}] -> GenServer.stop(pid, :normal)
      [] -> :ok
    end
  end

  @impl true
  def init(%Flight{} = flight) do
    Process.flag(:trap_exit, true)
    FlightLog.info(flight.id, :publisher, "Public feed starting")

    if Application.get_env(:drone_feed, :publisher_enabled, true) do
      FlightLog.info(flight.id, :mux, "Ensuring STANAG publish TS…")

      case StanagMux.ensure_publish_ts(flight) do
        {:ok, ts_path} ->
          path = MediaURLs.stream_path(:vod, flight.id)
          # Clear any prior udp+mpegts dynamic source so the path accepts SRT publish.
          wait_for_mediamtx()
          _ = MediaMTX.delete_path(path)
          # Brief pause so delete settles before FFmpeg publishes.
          Process.sleep(300)

          FlightLog.info(flight.id, :mux, "Publish TS ready", %{
            path: Path.basename(ts_path)
          })

          FlightLog.info(flight.id, :publisher, "MediaMTX SRT MPEG-TS publish → #{path}")

          {ports, labels} = start_ffmpeg_processes(flight, ts_path)

          FlightLog.info(flight.id, :publisher, "FFmpeg publishers up", %{
            processes: map_size(labels)
          })

          {:ok,
           %{
             flight_id: flight.id,
             ports: ports,
             port_labels: labels,
             flight: flight,
             ts_path: ts_path,
             udp_port: nil
           }}

        {:error, reason} ->
          fail_init(flight.id, reason)
      end
    else
      Logger.info("Publisher dry-run for flight #{flight.id} (ffmpeg disabled)")
      FlightLog.warn(flight.id, :publisher, "FFmpeg disabled (dry-run / test mode)")

      {:ok,
       %{
         flight_id: flight.id,
         ports: [],
         port_labels: %{},
         flight: flight,
         ts_path: nil,
         udp_port: nil
       }}
    end
  end

  defp fail_init(flight_id, reason) do
    msg = "Cannot publish: #{inspect(reason)}"
    Logger.error("Cannot publish flight #{flight_id}: #{inspect(reason)}")
    FlightLog.error(flight_id, :mux, msg)
    {:stop, reason}
  end

  @impl true
  def terminate(reason, state) do
    flight_id = Map.get(state, :flight_id)
    ports = Map.get(state, :ports, [])

    if flight_id do
      FlightLog.info(flight_id, :publisher, "Public feed stopping", %{reason: inspect(reason)})
    end

    Enum.each(ports, &safe_close/1)
    :ok
  end
  @impl true
  def handle_info({port, {:data, data}}, %{ports: ports, port_labels: labels} = state)
      when is_port(port) do
    if port in ports do
      label = Map.get(labels, port, "ffmpeg")
      line = port_line(data)

      if line != "" do
        level = ffmpeg_level(line)
        FlightLog.append(state.flight_id, level, label, line)
        Logger.log(logger_level(level), "ffmpeg[#{state.flight_id}/#{label}]: #{line}")
      end
    end

    {:noreply, state}
  end

  def handle_info(
        {port, {:exit_status, status}},
        %{ports: ports, port_labels: labels} = state
      )
      when is_port(port) do
    if port in ports do
      label = Map.get(labels, port, "ffmpeg")

      FlightLog.warn(
        state.flight_id,
        label,
        "Process exited with status #{status}; restarting in 1s"
      )

      Logger.warning(
        "ffmpeg for flight #{state.flight_id} (#{label}) exited with #{status}; restarting"
      )

      safe_close(port)
      Process.send_after(self(), {:restart_publisher, label}, 500)

      {:noreply,
       %{
         state
         | ports: List.delete(ports, port),
           port_labels: Map.delete(labels, port)
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, reason}, %{ports: ports, port_labels: labels} = state)
      when is_port(port) do
    if port in ports do
      label = Map.get(labels, port, "ffmpeg")
      FlightLog.warn(state.flight_id, :ffmpeg, "Port EXIT #{inspect(reason)}; restarting")
      Logger.warning("ffmpeg port EXIT #{inspect(reason)}; restarting")
      safe_close(port)
      Process.send_after(self(), {:restart_publisher, label}, 500)

      {:noreply,
       %{
         state
         | ports: List.delete(ports, port),
           port_labels: Map.delete(labels, port)
       }}
    else
      {:noreply, state}
    end
  end

  def handle_info({:restart_publisher, label}, state) do
    if Map.values(state.port_labels) |> Enum.member?(label) do
      {:noreply, state}
    else
      case open_one(state.flight, state.ts_path, label) do
        nil ->
          Process.send_after(self(), {:restart_publisher, label}, 2_000)
          {:noreply, state}

        port ->
          {:noreply,
           %{
             state
             | ports: [port | state.ports],
               port_labels: Map.put(state.port_labels, port, label)
           }}
      end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_ffmpeg_processes(%Flight{} = flight, ts_path) when is_binary(ts_path) do
    case open_one(flight, ts_path, "ffmpeg-mpegts") do
      nil -> {[], %{}}
      port -> {[port], %{port => "ffmpeg-mpegts"}}
    end
  end

  defp open_one(flight, ts_path, "ffmpeg-mpegts") do
    open_ffmpeg(flight.id, mpegts_srt_args(flight, ts_path), "ffmpeg-mpegts")
  end

  defp open_one(_flight, _ts_path, _label), do: nil

  @doc false
  def mpegts_srt_args(%Flight{} = flight, ts_path) do
    target = MediaURLs.publish_srt_mpegts_url(:vod, flight.id, flight.stream_key)
    height = publish_height()
    bitrate = publish_video_bitrate()
    maxrate = publish_video_maxrate()
    bufsize = publish_video_bufsize()
    gop = publish_gop()
    preset = publish_x264_preset()
    profile = publish_x264_profile()

    scale_filter =
      if height do
        ["-vf", "scale=-2:#{height}"]
      else
        []
      end

    [
      "-hide_banner",
      "-loglevel",
      "warning",
      # Real-time pacing for live pull clients.
      "-re",
      "-stream_loop",
      "-1",
      # Continuous PTS across loops (FFmpeg offsets on each iteration).
      "-fflags",
      "+genpts+igndts",
      "-avoid_negative_ts",
      "make_zero",
      "-i",
      ts_path,
      "-map",
      "0:v:0",
      "-map",
      "0:d:0?",
      "-c:v",
      "libx264",
      "-preset",
      preset,
      "-tune",
      "zerolatency",
      "-profile:v",
      profile,
      "-pix_fmt",
      "yuv420p"
    ] ++
      scale_filter ++
      [
        "-b:v",
        bitrate,
        "-maxrate",
        maxrate,
        "-bufsize",
        bufsize,
        # IDR ~1–2s so MediaMTX HLS / late SRT joiners get SPS/PPS + keyframe.
        "-g",
        Integer.to_string(gop),
        "-keyint_min",
        Integer.to_string(gop),
        "-sc_threshold",
        "0",
        "-bf",
        "0",
        "-c:d",
        "copy",
        "-muxdelay",
        "0",
        "-muxpreload",
        "0",
        "-flush_packets",
        "1",
        "-f",
        "mpegts",
        # Docker-local SRT into MediaMTX: modest µs latency, default buffers.
        # Huge sndbuf/rcvbuf made the outbound stream bursty for remote pullers.
        target <> "&latency=#{publish_srt_latency_us()}&transtype=live"
      ]
  end

  defp publish_srt_latency_us do
    Application.get_env(:drone_feed, :publish_srt_latency_us, 500_000)
  end

  # nil height = keep source resolution (still re-encodes for live-style IDRs).
  defp publish_height do
    case Application.get_env(:drone_feed, :publish_video_height, 1080) do
      nil -> nil
      0 -> nil
      "0" -> nil
      "source" -> nil
      h when is_integer(h) and h > 0 -> h
      h when is_binary(h) ->
        case Integer.parse(h) do
          {n, _} when n > 0 -> n
          _ -> 1080
        end
      _ -> 1080
    end
  end

  defp publish_video_bitrate,
    do: Application.get_env(:drone_feed, :publish_video_bitrate, "6M") |> to_string()

  defp publish_video_maxrate,
    do: Application.get_env(:drone_feed, :publish_video_maxrate, "8M") |> to_string()

  defp publish_video_bufsize,
    do: Application.get_env(:drone_feed, :publish_video_bufsize, "4M") |> to_string()

  defp publish_gop do
    case Application.get_env(:drone_feed, :publish_gop, 30) do
      n when is_integer(n) and n > 0 -> n
      n when is_binary(n) ->
        case Integer.parse(n) do
          {v, _} when v > 0 -> v
          _ -> 30
        end
      _ -> 30
    end
  end

  defp publish_x264_preset,
    do: Application.get_env(:drone_feed, :publish_x264_preset, "veryfast") |> to_string()

  defp publish_x264_profile,
    do: Application.get_env(:drone_feed, :publish_x264_profile, "main") |> to_string()

  defp wait_for_mediamtx do
    Enum.reduce_while(1..20, :ok, fn _, _ ->
      case MediaMTX.ping() do
        :ok -> {:halt, :ok}
        _ ->
          Process.sleep(250)
          {:cont, :ok}
      end
    end)
  end

  defp open_ffmpeg(flight_id, args, label) do
    ffmpeg = Application.fetch_env!(:drone_feed, :ffmpeg_path)
    FlightLog.info(flight_id, label, "Starting FFmpeg → MediaMTX")
    Logger.info("Starting FFmpeg (#{label}) for flight publish")

    Port.open(
      {:spawn_executable, ffmpeg_executable(ffmpeg)},
      [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 2048},
        args: args
      ]
    )
  rescue
    error ->
      FlightLog.error(flight_id, label, "Failed to start: #{inspect(error)}")
      Logger.error("Failed to start FFmpeg (#{label}): #{inspect(error)}")
      nil
  end

  defp ffmpeg_executable(path) do
    case :os.find_executable(String.to_charlist(path)) do
      false -> String.to_charlist(path)
      found -> found
    end
  end

  defp port_line({:eol, line}), do: line |> to_string() |> String.trim()
  defp port_line({:noeol, line}), do: line |> to_string() |> String.trim()
  defp port_line(other), do: other |> to_string() |> String.trim()

  defp ffmpeg_level(line) do
    down = String.downcase(line)

    cond do
      String.contains?(down, "error") or String.contains?(down, "failed") -> :error
      String.contains?(down, "warning") or String.contains?(down, "deprecated") -> :warn
      true -> :info
    end
  end

  defp logger_level(:error), do: :error
  defp logger_level(:warn), do: :warning
  defp logger_level(_), do: :info

  defp safe_close(port) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end
  rescue
    _ -> :ok
  end

  defp safe_close(_), do: :ok
end
