defmodule DroneFeed.Streaming.StanagMux do
  @moduledoc """
  Builds a normalized MPEG-TS with MISB KLV for publish.

  Consumer DJI (MP4 + .SRT) and enterprise TS+KLV both become the same
  STANAG-style transport that research tools can pull (prefer SRT MPEG-TS).
  """

  require Logger

  alias DroneFeed.Flights.Flight
  alias DroneFeed.Streaming.FlightLog

  @doc """
  Returns `{:ok, path}` to a cached `publish_stanag.ts` beside the flight assets.
  """
  def ensure_publish_ts(%Flight{} = flight) do
    out = output_path(flight)

    if fresh?(flight, out) do
      FlightLog.debug(flight.id, :mux, "Using cached publish TS", %{path: Path.basename(out)})
      {:ok, out}
    else
      build(flight, out)
    end
  end

  def output_path(%Flight{video_path: video_path}) do
    Path.join(Path.dirname(video_path), "publish_stanag.ts")
  end

  defp fresh?(%Flight{} = flight, out) do
    File.exists?(out) and
      mtime(out) >= mtime(flight.video_path) and
      (is_nil(flight.srt_path) or not File.exists?(flight.srt_path) or
         mtime(out) >= mtime(flight.srt_path)) and
      (is_nil(flight.klv_path) or not File.exists?(flight.klv_path) or
         mtime(out) >= mtime(flight.klv_path))
  end

  defp build(%Flight{} = flight, out) do
    script = mux_script()
    python = System.find_executable("python3") || "python3"

    args =
      [
        script,
        "--video",
        flight.video_path,
        "--output",
        out
      ]
      |> maybe_arg("--srt", flight.srt_path)
      |> maybe_arg("--klv", flight.klv_path)

    Logger.info("Building STANAG publish TS for flight #{flight.id}")
    FlightLog.info(flight.id, :mux, "Building STANAG publish TS (python mux)…")

    case System.cmd(python, args, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info(String.trim(output))
        FlightLog.info(flight.id, :mux, "Mux OK", %{detail: String.slice(String.trim(output), 0, 240)})
        {:ok, out}

      {output, code} ->
        Logger.error("Stanag mux failed (#{code}): #{output}")
        FlightLog.error(flight.id, :mux, "Mux failed (#{code})", %{
          detail: String.slice(output, 0, 500)
        })
        {:error, {:mux_failed, code, output}}
    end
  end

  defp maybe_arg(args, _flag, path) when path in [nil, ""], do: args
  defp maybe_arg(args, flag, path), do: args ++ [flag, path]

  defp mux_script do
    Application.get_env(:drone_feed, :mux_script) ||
      Path.expand("../../../../../scripts/mux_to_stanag.py", __DIR__)
  end

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end
end
