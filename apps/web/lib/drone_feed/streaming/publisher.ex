defmodule DroneFeed.Streaming.Publisher do
  @moduledoc """
  Republishes a recorded flight as a unified STANAG-style MPEG-TS feed.

  Both consumer DJI (MP4 + SRT) and enterprise TS+KLV are normalized via
  `StanagMux` into `publish_stanag.ts`, then FFmpeg loops the full TS
  (including MISB KLV) into MediaMTX over **SRT** (`publish:vod/<id>`).

  MediaMTX re-serves that path as SRT/RTSP/RTMP for pull clients. SRT is used
  for ingest (not UDP) so loop seeks and high bitrate do not gap the source.
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

  defp mpegts_srt_args(%Flight{} = flight, ts_path) do
    target = MediaURLs.publish_srt_mpegts_url(:vod, flight.id, flight.stream_key)

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
      "0",
      "-c",
      "copy",
      "-muxdelay",
      "0",
      "-muxpreload",
      "0",
      "-flush_packets",
      "1",
      "-f",
      "mpegts",
      # Live SRT: latency + large buffers for ~100Mbps 4K.
      target <> "&latency=4000000&transtype=live&sndbuf=120000000&rcvbuf=120000000"
    ]
  end

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
