defmodule DroneFeedWeb.MetadataController do
  @moduledoc """
  Serves consumer-drone sidecar telemetry (SRT) and enterprise KLV while a flight is publishing.

  Tools pull video from RTMP/RTSP and fetch paired metadata here with the same stream key.
  """
  use DroneFeedWeb, :controller

  alias DroneFeed.Flights

  def show(conn, %{"id" => id, "kind" => kind} = params) do
    key = params["key"] || params["pass"] || ""

    with {:ok, flight} <- fetch_publishing_flight(id, key),
         {:ok, path, content_type, filename} <- metadata_file(flight, kind) do
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
      |> put_resp_header("cache-control", "no-store")
      |> send_file(200, path)
    else
      {:error, :unauthorized} ->
        send_resp(conn, 401, "unauthorized")

      {:error, :not_found} ->
        send_resp(conn, 404, "not found")

      {:error, :not_publishing} ->
        send_resp(conn, 403, "flight is not publishing")
    end
  end

  defp fetch_publishing_flight(id, key) do
    case Flights.get_flight(id) do
      %{publishing: true, stream_key: ^key} = flight when key != "" ->
        {:ok, flight}

      %{publishing: true} ->
        {:error, :unauthorized}

      %{publishing: false} ->
        {:error, :not_publishing}

      nil ->
        {:error, :not_found}
    end
  end

  defp metadata_file(%{srt_path: path}, "srt") when is_binary(path) do
    if File.exists?(path) do
      {:ok, path, "text/plain; charset=utf-8", "telemetry.srt"}
    else
      {:error, :not_found}
    end
  end

  defp metadata_file(%{klv_path: path}, "klv") when is_binary(path) do
    if File.exists?(path) do
      {:ok, path, "application/octet-stream", Path.basename(path)}
    else
      {:error, :not_found}
    end
  end

  defp metadata_file(_, _), do: {:error, :not_found}
end
