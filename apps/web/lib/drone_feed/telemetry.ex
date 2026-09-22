defmodule DroneFeed.Telemetry do
  @moduledoc """
  Parses consumer DJI .SRT telemetry and enterprise KLV tracks into map points
  for the browser UI (lat/lon/alt). This is separate from Public-feed STANAG
  egress: derived heading/speed for research tools are added in `mux_to_stanag.py`,
  not here.
  """

  alias DroneFeed.Flights.Flight

  def for_flight(%Flight{} = flight) do
    cond do
      srt?(flight) -> from_srt(flight.srt_path)
      klv_source?(flight) -> from_klv_source(flight)
      true -> empty("No telemetry sidecar or in-band KLV detected yet.")
    end
  end

  defp srt?(%Flight{srt_path: path}) when is_binary(path), do: File.exists?(path)
  defp srt?(_), do: false

  defp klv_source?(%Flight{klv_path: path}) when is_binary(path), do: File.exists?(path)

  defp klv_source?(%Flight{video_path: path}) when is_binary(path) do
    File.exists?(path) and has_inband_klv?(path)
  end

  defp klv_source?(_), do: false

  # Content-based: extension is irrelevant (.H264 / .mp4 can be MPEG-TS + KLV).
  defp has_inband_klv?(path) do
    case System.cmd(
           "ffprobe",
           [
             "-v",
             "error",
             "-show_entries",
             "stream=codec_type,codec_name",
             "-of",
             "csv=p=0",
             path
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split(["\n", "\r"], trim: true)
        |> Enum.any?(fn line ->
          parts =
            line
            |> String.downcase()
            |> String.split(",", trim: true)

          "data" in parts or "klv" in parts
        end)

      _ ->
        false
    end
  end

  def from_srt(path) when is_binary(path) do
    text = File.read!(path)
    points = parse_srt(text)

    %{
      source: :srt,
      points: downsample(points, 400),
      all_count: length(points),
      raw_preview: raw_sidecar_preview(text),
      stats: stats(points),
      message: nil
    }
  end

  def from_klv_source(%Flight{} = flight) do
    cache = Path.join(Path.dirname(flight.video_path), "telemetry_track.json")
    source = flight.klv_path || flight.video_path

    case ensure_klv_json(source, cache) do
      {:ok, []} ->
        empty("KLV track found but no position samples could be decoded.")

      {:ok, points} ->
        %{
          source: :klv,
          points: downsample(points, 400),
          all_count: length(points),
          raw_preview: Jason.encode!(Enum.take(points, 8), pretty: true),
          stats: stats(points),
          message: nil
        }

      {:error, reason} ->
        empty(
          "Could not extract KLV track (#{inspect(reason)}). RTSP publish still carries in-band KLV."
        )
    end
  end

  defp ensure_klv_json(source, cache) do
    if File.exists?(cache) and fresh?(cache, source) do
      case decode_cache(cache) do
        {:ok, []} ->
          File.rm(cache)
          extract_klv_json(source, cache)

        other ->
          other
      end
    else
      extract_klv_json(source, cache)
    end
  end

  defp decode_cache(cache) do
    with {:ok, body} <- File.read(cache),
         {:ok, data} <- Jason.decode(body) do
      {:ok, Enum.map(data, &normalize_point/1)}
    end
  end

  defp extract_klv_json(source, cache) do
    script = extract_script()
    python = Application.get_env(:drone_feed, :python_path) || System.find_executable("python3") || "python3"

    case System.cmd(python, [script, "--input", source, "--output", cache], stderr_to_stdout: true) do
      {_, 0} -> decode_cache(cache)
      {out, code} -> {:error, {code, String.slice(out, 0, 400)}}
    end
  end

  defp extract_script do
    Application.get_env(:drone_feed, :extract_klv_script) ||
      Path.expand("../../../../../scripts/extract_klv_track.py", __DIR__)
  end

  defp normalize_point(p) when is_map(p) do
    %{
      t_ms: Map.get(p, "t_ms") || Map.get(p, :t_ms) || 0,
      lat: (Map.get(p, "lat") || Map.get(p, :lat) || 0) * 1.0,
      lon: (Map.get(p, "lon") || Map.get(p, :lon) || 0) * 1.0,
      alt: Map.get(p, "alt") || Map.get(p, :alt),
      raw: Map.get(p, "raw") || Map.get(p, :raw)
    }
  end

  def parse_srt(text) when is_binary(text) do
    text
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.flat_map(fn block ->
      case parse_srt_block(block) do
        nil -> []
        point -> [point]
      end
    end)
  end

  defp parse_srt_block(block) do
    geo =
      Regex.run(
        ~r/latitude:\s*([-\d.]+).*?longitude:\s*([-\d.]+).*?altitude:\s*([-\d.]+)/is,
        block
      )

    timing = Regex.run(~r/(\d{2}):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->/, block)

    with [_, lat_s, lon_s, alt_s] <- geo,
         [_, hh, mm, ss, ms] <- timing do
      t_ms =
        String.to_integer(hh) * 3_600_000 +
          String.to_integer(mm) * 60_000 +
          String.to_integer(ss) * 1_000 +
          String.to_integer(String.pad_trailing(ms, 3, "0"))

      lat = String.to_float(lat_s)
      lon = String.to_float(lon_s)
      alt = String.to_float(alt_s)

      %{
        t_ms: t_ms,
        lat: lat,
        lon: lon,
        alt: alt,
        raw: format_srt_cue(block, t_ms, lat, lon, alt)
      }
    else
      _ -> nil
    end
  end

  @doc false
  def format_srt_cue(block, t_ms, lat, lon, alt) do
    body =
      block
      |> String.replace(~r/<[^>]+>/, " ")
      |> String.replace(~r/\r\n?/, "\n")
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(fn line ->
        line == "" or
          Regex.match?(~r/^\d+$/, line) or
          Regex.match?(~r/^\d{2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->/, line)
      end)
      |> Enum.join(" ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    fields = extract_bracket_fields(body)
    meta = extract_srt_meta(body)

    camera =
      [
        format_field(fields, "iso", &("ISO " <> &1)),
        format_field(fields, "shutter", &("shutter " <> &1)),
        format_fnum(Map.get(fields, "fnum")),
        format_field(fields, "ev", &("EV " <> &1)),
        format_ct(Map.get(fields, "ct")),
        format_field(fields, "color_md", &("color " <> &1))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  ·  ")

    lens =
      [
        format_focal(Map.get(fields, "focal_len")),
        format_zoom(Map.get(fields, "dzoom_ratio"))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("  ·  ")

    lines =
      [
        Enum.join(
          [
            "t " <> format_t_ms(t_ms),
            meta[:cnt] && ("#" <> meta[:cnt]),
            meta[:diff] && ("Δ " <> meta[:diff])
          ]
          |> Enum.reject(&is_nil/1),
          "  ·  "
        ),
        meta[:captured],
        if(camera != "", do: camera),
        if(lens != "", do: lens),
        "#{fmt_coord(lat)}, #{fmt_coord(lon)}  ·  #{fmt_alt(alt)}"
      ]
      |> Enum.reject(&is_nil/1)

    Enum.join(lines, "\n")
  end

  defp extract_bracket_fields(body) do
    ~r/\[([a-zA-Z_]+)\s*:\s*([^\]]+)\]/
    |> Regex.scan(body)
    |> Map.new(fn [_, key, value] -> {String.downcase(key), String.trim(value)} end)
  end

  defp extract_srt_meta(body) do
    cnt =
      case Regex.run(~r/SrtCnt\s*:\s*(\d+)/i, body) do
        [_, n] -> n
        _ -> nil
      end

    diff =
      case Regex.run(~r/DiffTime\s*:\s*([\d.]+\s*ms)/i, body) do
        [_, d] -> String.trim(d)
        _ -> nil
      end

    captured =
      case Regex.run(
             ~r/(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})[,.]([\d,]+)/,
             body
           ) do
        [_, stamp, frac] ->
          frac =
            frac
            |> String.replace(",", "")
            |> String.slice(0, 6)
            |> String.pad_trailing(6, "0")

          stamp <> "." <> frac

        _ ->
          nil
      end

    %{cnt: cnt, diff: diff, captured: captured}
  end

  defp format_field(fields, key, fun) do
    case Map.get(fields, key) do
      nil -> nil
      "" -> nil
      value -> fun.(value)
    end
  end

  defp format_fnum(nil), do: nil

  defp format_fnum(value) do
    case Float.parse(value) do
      {n, _} when n >= 20 -> "f/#{:erlang.float_to_binary(n / 100.0, decimals: 2)}"
      {n, _} -> "f/#{:erlang.float_to_binary(n * 1.0, decimals: 2)}"
      :error -> "f/" <> value
    end
  end

  defp format_ct(nil), do: nil
  defp format_ct(value), do: value <> "K"

  defp format_focal(nil), do: nil

  defp format_focal(value) do
    case Float.parse(value) do
      {n, _} when n >= 50 -> "#{:erlang.float_to_binary(n / 10.0, decimals: 1)} mm"
      {n, _} -> "#{:erlang.float_to_binary(n * 1.0, decimals: 1)} mm"
      :error -> value <> " mm"
    end
  end

  defp format_zoom(nil), do: nil

  defp format_zoom(value) do
    # DJI: "10000, delta:0" → 1.00×
    num =
      value
      |> String.split(",", parts: 2)
      |> hd()
      |> String.trim()

    case Float.parse(num) do
      {n, _} when n >= 100 -> "zoom #{:erlang.float_to_binary(n / 10_000.0, decimals: 2)}×"
      {n, _} -> "zoom #{:erlang.float_to_binary(n * 1.0, decimals: 2)}×"
      :error -> "zoom " <> value
    end
  end

  defp format_t_ms(t_ms) when is_integer(t_ms) do
    hh = div(t_ms, 3_600_000)
    rem = rem(t_ms, 3_600_000)
    mm = div(rem, 60_000)
    rem = rem(rem, 60_000)
    ss = div(rem, 1_000)
    ms = rem(rem, 1_000)

    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [hh, mm, ss, ms])
    |> IO.iodata_to_binary()
  end

  defp fmt_coord(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 6)
  defp fmt_coord(_), do: "—"

  defp fmt_alt(v) when is_number(v), do: :erlang.float_to_binary(v * 1.0, decimals: 1) <> " m"
  defp fmt_alt(_), do: "— m"

  @raw_preview_limit 120_000

  defp raw_sidecar_preview(text) when byte_size(text) <= @raw_preview_limit, do: text

  defp raw_sidecar_preview(text) do
    String.slice(text, 0, @raw_preview_limit) <>
      "\n\n… truncated (#{byte_size(text)} bytes total)"
  end

  defp stats([]), do: %{lat: nil, lon: nil, alt: nil, alt_min: nil, alt_max: nil}

  defp stats(points) do
    alts = points |> Enum.map(& &1.alt) |> Enum.reject(&is_nil/1)
    last = List.last(points)
    first = hd(points)

    %{
      lat: last.lat,
      lon: last.lon,
      alt: last.alt,
      alt_min: if(alts != [], do: Enum.min(alts)),
      alt_max: if(alts != [], do: Enum.max(alts)),
      start_lat: first.lat,
      start_lon: first.lon
    }
  end

  defp downsample(points, max) when length(points) <= max, do: points

  defp downsample(points, max) do
    step = max(div(length(points), max), 1)
    points |> Enum.take_every(step) |> Enum.take(max)
  end

  defp empty(message) do
    %{
      source: :none,
      points: [],
      all_count: 0,
      raw_preview: "",
      stats: stats([]),
      message: message
    }
  end

  defp fresh?(cache, source) do
    case {File.stat(cache), File.stat(source)} do
      {{:ok, %{mtime: c}}, {:ok, %{mtime: s}}} -> c >= s
      _ -> false
    end
  end
end
