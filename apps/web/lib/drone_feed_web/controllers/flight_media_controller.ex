defmodule DroneFeedWeb.FlightMediaController do
  @moduledoc """
  Authenticated progressive download of a flight's browser-playable preview.
  """
  use DroneFeedWeb, :controller

  alias DroneFeed.Flights
  alias DroneFeed.Flights.BrowserPreview

  def show(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    flight = Flights.get_flight!(scope, id)

    cond do
      BrowserPreview.ready?(flight) ->
        case BrowserPreview.ensure(flight) do
          {:ok, path, content_type} ->
            serve(conn, path, content_type)

          {:error, _} ->
            send_resp(conn, 404, "media unavailable")
        end

      true ->
        BrowserPreview.warm(flight)

        conn
        |> put_resp_header("retry-after", "3")
        |> send_resp(503, "preview preparing")
    end
  rescue
    Ecto.NoResultsError ->
      send_resp(conn, 404, "not found")
  end

  defp serve(conn, path, content_type) do
    %File.Stat{size: size} = File.stat!(path)

    case parse_range(get_req_header(conn, "range"), size) do
      :full ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-length", Integer.to_string(size))
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_file(200, path)

      {:partial, start, length, end_pos} ->
        conn
        |> put_resp_content_type(content_type)
        |> put_resp_header("accept-ranges", "bytes")
        |> put_resp_header("content-range", "bytes #{start}-#{end_pos}/#{size}")
        |> put_resp_header("content-length", Integer.to_string(length))
        |> put_resp_header("cache-control", "private, max-age=3600")
        |> send_file(206, path, start, length)

      :invalid ->
        conn
        |> put_resp_header("content-range", "bytes */#{size}")
        |> send_resp(416, "requested range not satisfiable")
    end
  end

  defp parse_range([], _size), do: :full

  defp parse_range(["bytes=" <> spec | _], size) do
    case String.split(spec, "-", parts: 2) do
      [start_s, ""] ->
        with {start, ""} <- Integer.parse(start_s),
             true <- start >= 0 and start < size do
          end_pos = size - 1
          {:partial, start, end_pos - start + 1, end_pos}
        else
          _ -> :invalid
        end

      [start_s, end_s] ->
        with {start, ""} <- Integer.parse(start_s),
             {end_pos, ""} <- Integer.parse(end_s),
             true <- start >= 0 and end_pos >= start and end_pos < size do
          {:partial, start, end_pos - start + 1, end_pos}
        else
          _ -> :invalid
        end

      _ ->
        :invalid
    end
  end

  defp parse_range(_, _), do: :full
end
