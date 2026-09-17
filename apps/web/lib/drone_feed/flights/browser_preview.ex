defmodule DroneFeed.Flights.BrowserPreview do
  @moduledoc """
  Ensures a browser-playable media file for the flight detail player.

  MP4/WebM are served as-is. MPEG-TS / MPEG-PS and other containers are remuxed
  (or lightly transcoded) into a cached `preview.mp4` beside the original assets.
  """

  require Logger

  alias DroneFeed.Flights.Flight

  @browser_ext ~w(.mp4 .webm .ogg)

  def ensure(%Flight{video_path: path} = flight) when is_binary(path) do
    ext = path |> Path.extname() |> String.downcase()

    cond do
      not File.exists?(path) ->
        {:error, :missing}

      ext in @browser_ext ->
        {:ok, path, content_type(ext)}

      true ->
        remux(flight)
    end
  end

  def ensure(_), do: {:error, :missing}

  defp remux(%Flight{video_path: source} = _flight) do
    out = Path.join(Path.dirname(source), "preview.mp4")

    if File.exists?(out) and mtime(out) >= mtime(source) do
      {:ok, out, "video/mp4"}
    else
      ffmpeg = Application.get_env(:drone_feed, :ffmpeg_path) || System.find_executable("ffmpeg") || "ffmpeg"

      case run_ffmpeg(ffmpeg, copy_args(source, out)) do
        :ok ->
          {:ok, out, "video/mp4"}

        {:error, _} ->
          case run_ffmpeg(ffmpeg, transcode_args(source, out)) do
            :ok -> {:ok, out, "video/mp4"}
            {:error, reason} -> {:error, reason}
          end
      end
    end
  end

  defp copy_args(source, out) do
    [
      "-y",
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      source,
      "-map",
      "0:v:0?",
      "-map",
      "0:a:0?",
      "-c",
      "copy",
      "-movflags",
      "+faststart",
      out
    ]
  end

  defp transcode_args(source, out) do
    [
      "-y",
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      source,
      "-map",
      "0:v:0?",
      "-map",
      "0:a:0?",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "23",
      "-c:a",
      "aac",
      "-movflags",
      "+faststart",
      out
    ]
  end

  defp run_ffmpeg(ffmpeg, args) do
    case System.cmd(ffmpeg, args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {out, code} ->
        Logger.warning("preview ffmpeg failed (#{code}): #{String.slice(out, 0, 300)}")
        {:error, {:ffmpeg, code}}
    end
  end

  defp content_type(".webm"), do: "video/webm"
  defp content_type(".ogg"), do: "video/ogg"
  defp content_type(_), do: "video/mp4"

  defp mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: m}} -> m
      _ -> {{1970, 1, 1}, {0, 0, 0}}
    end
  end
end
