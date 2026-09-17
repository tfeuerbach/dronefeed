defmodule DroneFeed.Streaming.Publisher do
  @moduledoc """
  Republishes a recorded flight as a unified STANAG-style MPEG-TS feed.

  Both consumer DJI (MP4 + SRT) and enterprise TS+KLV are normalized via
  `StanagMux` into `publish_stanag.ts`, then:

  - **RTSP** (primary): full copy including MISB KLV / data PID for research tools
  - **RTMP** (secondary): A/V only for simple players (FLV cannot carry KLV)
  """

  use GenServer
  require Logger

  alias DroneFeed.Flights.Flight
  alias DroneFeed.MediaURLs
  alias DroneFeed.Streaming.FlightLog
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
          FlightLog.info(flight.id, :mux, "Publish TS ready", %{path: Path.basename(ts_path)})
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
             ts_path: ts_path
           }}

        {:error, reason} ->
          msg = "Cannot publish: #{inspect(reason)}"
          Logger.error("Cannot publish flight #{flight.id}: #{inspect(reason)}")
          FlightLog.error(flight.id, :mux, msg)
          {:stop, reason}
      end
    else
      Logger.info("Publisher dry-run for flight #{flight.id} (ffmpeg disabled)")
      FlightLog.warn(flight.id, :publisher, "FFmpeg disabled (dry-run / test mode)")
      {:ok, %{flight_id: flight.id, ports: [], port_labels: %{}, flight: flight, ts_path: nil}}
    end
  end

  @impl true
  def terminate(reason, %{flight_id: flight_id, ports: ports}) when is_list(ports) do
    FlightLog.info(flight_id, :publisher, "Public feed stopping", %{reason: inspect(reason)})
    Enum.each(ports, &safe_close/1)
    :ok
  end

  def terminate(_reason, _state), do: :ok

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
        %{ports: ports, port_labels: labels, ts_path: ts_path} = state
      )
      when is_port(port) do
    if port in ports do
      label = Map.get(labels, port, "ffmpeg")

      FlightLog.warn(state.flight_id, label, "Process exited with status #{status}; restarting in 1s")

      Logger.warning("ffmpeg for flight #{state.flight_id} (#{label}) exited with #{status}; restarting")

      Enum.each(ports, &safe_close/1)
      Process.sleep(1_000)
      {new_ports, new_labels} = start_ffmpeg_processes(state.flight, ts_path)
      {:noreply, %{state | ports: new_ports, port_labels: new_labels}}
    else
      {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, reason}, %{ports: ports, ts_path: ts_path} = state)
      when is_port(port) do
    if port in ports do
      FlightLog.warn(state.flight_id, :ffmpeg, "Port EXIT #{inspect(reason)}; restarting")
      Logger.warning("ffmpeg port EXIT #{inspect(reason)}; restarting")
      Enum.each(ports, &safe_close/1)
      Process.sleep(1_000)
      {new_ports, new_labels} = start_ffmpeg_processes(state.flight, ts_path)
      {:noreply, %{state | ports: new_ports, port_labels: new_labels}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp start_ffmpeg_processes(%Flight{} = flight, ts_path) when is_binary(ts_path) do
    specs = [
      {"ffmpeg-rtsp", rtsp_full_args(flight, ts_path)},
      {"ffmpeg-rtmp", rtmp_av_args(flight, ts_path)}
    ]

    Enum.reduce(specs, {[], %{}}, fn {label, args}, {ports, labels} ->
      case open_ffmpeg(flight.id, args, label) do
        nil ->
          {ports, labels}

        port ->
          {[port | ports], Map.put(labels, port, label)}
      end
    end)
    |> then(fn {ports, labels} -> {Enum.reverse(ports), labels} end)
  end

  defp start_ffmpeg_processes(_, _), do: {[], %{}}

  defp rtsp_full_args(%Flight{} = flight, ts_path) do
    target = MediaURLs.publish_target(:rtsp, :vod, flight.id, flight.stream_key)

    [
      "-hide_banner",
      "-loglevel",
      "warning",
      "-re",
      "-stream_loop",
      "-1",
      "-i",
      ts_path,
      "-map",
      "0",
      "-c",
      "copy",
      "-f",
      "rtsp",
      "-rtsp_transport",
      "tcp",
      target
    ]
  end

  defp rtmp_av_args(%Flight{} = flight, ts_path) do
    target = MediaURLs.publish_target(:rtmp, :vod, flight.id, flight.stream_key)

    [
      "-hide_banner",
      "-loglevel",
      "warning",
      "-re",
      "-stream_loop",
      "-1",
      "-i",
      ts_path,
      "-map",
      "0:v:0?",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      "-f",
      "flv",
      target
    ]
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
