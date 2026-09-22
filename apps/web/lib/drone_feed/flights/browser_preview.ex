defmodule DroneFeed.Flights.BrowserPreview do
  @moduledoc """
  Ensures a browser-playable media file for the flight detail player.

  Extension alone is not trustworthy — samples are often MPEG-TS / MPEG-2
  mislabeled as `.mp4`. We probe codec + container; only H.264/VP8/VP9/AV1 in a
  real MP4/WebM/Ogg container is served as-is. Everything else is remuxed or
  transcoded into a cached `preview.mp4` beside the original assets.

  Generation writes to `preview.mp4.part` and renames on success so crashes never
  leave a half-written file marked ready. Abandoned `.lock` / `.part` files are
  reclaimed automatically.
  """

  require Logger

  alias DroneFeed.Flights.Flight

  @browser_codecs MapSet.new(~w(h264 avc vp8 vp9 av1))
  @browser_format_tokens MapSet.new(~w(mp4 mov isom iso2 avc1 m4v webm matroska ogg))
  # ffmpeg on large MPEG-TS clips can take a while; only reclaim abandoned locks.
  @stale_lock_secs 15 * 60

  @doc """
  Returns a browser-playable path + content-type, generating `preview.mp4` when needed.
  """
  def ensure(%Flight{video_path: path} = flight) when is_binary(path) do
    cond do
      not File.exists?(path) ->
        {:error, :missing}

      preview_usable?(path, preview_path(path)) ->
        {:ok, preview_path(path), "video/mp4"}

      browser_playable?(path) ->
        ext = path |> Path.extname() |> String.downcase()
        {:ok, path, content_type(ext)}

      true ->
        remux(flight)
    end
  end

  def ensure(_), do: {:error, :missing}

  @doc """
  True when the original is already browser-safe or a fresh `preview.mp4` exists.
  """
  def ready?(%Flight{video_path: path}) when is_binary(path) do
    cond do
      not File.exists?(path) ->
        false

      # Prefer the cached preview check — probing a large MPEG-TS source on every
      # poll/media request is slow and can time out the player.
      preview_usable?(path, preview_path(path)) ->
        true

      browser_playable?(path) ->
        true

      true ->
        false
    end
  end

  def ready?(_), do: false

  @doc """
  Kick off preview generation in the background (idempotent).
  """
  def warm(%Flight{} = flight) do
    Task.start(fn ->
      case ensure(flight) do
        {:ok, _, _} ->
          :ok

        {:error, :busy} ->
          # Another worker holds the lock; polling will retry.
          :ok

        {:error, reason} ->
          Logger.warning("preview warm failed: #{inspect(reason)}")
      end
    end)

    :ok
  end

  @doc false
  def browser_playable_probe?(%{codec: codec, format: format})
      when is_binary(codec) and is_binary(format) do
    codec_ok?(codec) and format_ok?(format)
  end

  def browser_playable_probe?(_), do: false

  defp browser_playable?(path) do
    case probe(path) do
      {:ok, info} -> browser_playable_probe?(info)
      _ -> false
    end
  end

  defp remux(%Flight{video_path: source}) do
    out = preview_path(source)

    if preview_usable?(source, out) do
      {:ok, out, "video/mp4"}
    else
      with_lock(out, fn ->
        # Re-check after acquiring lock — another warm may have finished.
        if preview_complete?(source, out) do
          {:ok, out, "video/mp4"}
        else
          generate_preview(source, out)
        end
      end)
    end
  end

  # Fresh preview with no active lock. Clears abandoned locks / partials left by
  # killed ffmpeg or container restarts so media never stays 503 forever.
  defp preview_usable?(source, out) do
    reclaim_stale_artifacts(source, out)
    preview_complete?(source, out) and not File.exists?(lock_path(out))
  end

  defp preview_complete?(source, out) do
    File.exists?(out) and nonempty?(out) and mtime(out) >= mtime(source)
  end

  defp with_lock(out, fun) do
    lock = lock_path(out)
    _ = File.mkdir_p(Path.dirname(out))
    reclaim_lock_and_part(out)

    case open_exclusive(lock) do
      {:ok, io} ->
        run_locked(io, lock, fun)

      {:error, :eexist} ->
        reclaim_lock_and_part(out)

        case open_exclusive(lock) do
          {:ok, io} -> run_locked(io, lock, fun)
          {:error, :eexist} -> {:error, :busy}
          {:error, reason} -> lock_fallback(reason, fun)
        end

      {:error, reason} ->
        lock_fallback(reason, fun)
    end
  end

  defp reclaim_stale_artifacts(source, out) do
    reclaim_lock_and_part(out)

    # Empty / older-than-source preview without a lock → regenerate next ensure.
    if not File.exists?(lock_path(out)) and File.exists?(out) and
         not preview_complete?(source, out) do
      Logger.info("removing unusable preview #{out}")
      _ = File.rm(out)
    end

    :ok
  end

  defp reclaim_lock_and_part(out) do
    lock = lock_path(out)
    part = part_path(out)

    case File.stat(lock) do
      {:ok, %{mtime: lock_mtime}} ->
        preview_finished =
          File.exists?(out) and nonempty?(out) and mtime(out) >= lock_mtime

        stale = age_seconds(lock_mtime) > @stale_lock_secs

        if preview_finished or stale do
          Logger.info("clearing stale preview lock #{lock}")
          _ = File.rm(lock)
          _ = File.rm(part)

          if stale and File.exists?(out) and not nonempty?(out) do
            _ = File.rm(out)
          end
        end

      _ ->
        maybe_rm_orphan_part(part)
    end
  end

  defp maybe_rm_orphan_part(part) do
    case File.stat(part) do
      {:ok, %{mtime: mtime}} ->
        if age_seconds(mtime) > @stale_lock_secs do
          Logger.info("removing orphan preview part #{part}")
          _ = File.rm(part)
        end

      _ ->
        :ok
    end
  end

  defp generate_preview(source, out) do
    ffmpeg =
      Application.get_env(:drone_feed, :ffmpeg_path) || System.find_executable("ffmpeg") ||
        "ffmpeg"

    part = part_path(out)
    _ = File.rm(part)

    result =
      case probe(source) do
        {:ok, %{codec: codec}} ->
          if codec_ok?(codec) do
            case run_ffmpeg(ffmpeg, copy_args(source, part)) do
              :ok -> :ok
              {:error, _} -> run_ffmpeg(ffmpeg, transcode_args(source, part))
            end
          else
            run_ffmpeg(ffmpeg, transcode_args(source, part))
          end

        _ ->
          case run_ffmpeg(ffmpeg, copy_args(source, part)) do
            :ok -> :ok
            {:error, _} -> run_ffmpeg(ffmpeg, transcode_args(source, part))
          end
      end

    case result do
      :ok ->
        if nonempty?(part) and browser_playable?(part) do
          case File.rename(part, out) do
            :ok ->
              {:ok, out, "video/mp4"}

            {:error, reason} ->
              _ = File.rm(part)
              {:error, {:rename, reason}}
          end
        else
          _ = File.rm(part)
          {:error, :invalid_preview}
        end

      {:error, reason} ->
        _ = File.rm(part)
        {:error, reason}
    end
  end

  defp run_locked(io, lock, fun) do
    try do
      fun.()
    after
      File.close(io)
      File.rm(lock)
    end
  end

  defp open_exclusive(lock), do: File.open(lock, [:write, :exclusive])

  defp lock_fallback(reason, fun) do
    Logger.debug("preview lock unavailable (#{inspect(reason)}); generating without lock")
    fun.()
  end

  defp preview_path(source), do: Path.join(Path.dirname(source), "preview.mp4")
  defp lock_path(out), do: out <> ".lock"
  defp part_path(out), do: out <> ".part"

  defp nonempty?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > 0 -> true
      _ -> false
    end
  end

  defp probe(path) do
    ffprobe =
      Application.get_env(:drone_feed, :ffprobe_path) || System.find_executable("ffprobe") ||
        "ffprobe"

    args = [
      "-v",
      "error",
      "-select_streams",
      "v:0",
      "-show_entries",
      "stream=codec_name:format=format_name",
      "-of",
      "csv=p=0",
      path
    ]

    case System.cmd(ffprobe, args, stderr_to_stdout: true) do
      {out, 0} ->
        # csv=p=0 prints stream then format on separate lines (blank lines between).
        case String.split(out, ["\n", "\r"], trim: true) do
          [codec, format | _] ->
            {:ok,
             %{
               codec: String.downcase(String.trim(codec)),
               format: String.downcase(String.trim(format))
             }}

          _ ->
            {:error, :unparseable}
        end

      {out, code} ->
        Logger.debug("preview ffprobe failed (#{code}): #{String.slice(out, 0, 200)}")
        {:error, :probe_failed}
    end
  end

  defp codec_ok?(codec), do: MapSet.member?(@browser_codecs, codec)

  defp format_ok?(format) do
    tokens =
      format
      |> String.split(",", trim: true)
      |> MapSet.new()

    # MPEG-TS (even when named .mp4) is never browser-native.
    not MapSet.member?(tokens, "mpegts") and
      MapSet.size(MapSet.intersection(tokens, @browser_format_tokens)) > 0
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
      "-vf",
      "scale='min(1920,iw)':-2",
      "-c:v",
      "libx264",
      "-preset",
      "veryfast",
      "-crf",
      "23",
      "-pix_fmt",
      "yuv420p",
      "-c:a",
      "aac",
      "-ac",
      "2",
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

  defp age_seconds(erlang_mtime) do
    now = :calendar.local_time() |> :calendar.datetime_to_gregorian_seconds()
    then = :calendar.datetime_to_gregorian_seconds(erlang_mtime)
    max(now - then, 0)
  end
end
