defmodule DroneFeed.Streaming.MediaMTX do
  @moduledoc """
  Thin client for MediaMTX Control API (path add/delete for UDP MPEG-TS).
  """

  require Logger

  @doc """
  Configures a path to listen for MPEG-TS over UDP (add, or replace if present).
  """
  def add_udp_mpegts_path(path, port) when is_binary(path) and is_integer(port) do
    if enabled?() do
      body = Jason.encode!(%{"source" => "udp+mpegts://0.0.0.0:#{port}"})
      encoded = encode_path(path)

      case request(:post, "/v3/config/paths/add/#{encoded}", body) do
        :ok ->
          :ok

        {:error, {:http, status, _}} when status in [400, 409] ->
          request(:post, "/v3/config/paths/replace/#{encoded}", body)

        other ->
          other
      end
    else
      :ok
    end
  end

  @doc """
  Removes a dynamically configured path (best-effort).
  """
  def delete_path(path) when is_binary(path) do
    if enabled?() do
      case request(:post, "/v3/config/paths/delete/#{encode_path(path)}", "") do
        :ok -> :ok
        {:error, :not_found} -> :ok
        other -> other
      end
    else
      :ok
    end
  end

  defp enabled? do
    Application.get_env(:drone_feed, :mediamtx_api_enabled, true)
  end

  defp encode_path(path) do
    path
    |> String.trim_leading("/")
    |> URI.encode_www_form()
  end

  defp request(method, path, body) do
    base = Application.fetch_env!(:drone_feed, :mediamtx_api_url) |> String.trim_trailing("/")
    url = base <> path
    headers = [{"content-type", "application/json"}, {"accept", "application/json"}]

    result =
      case method do
        :post ->
          Req.post(url,
            body: body,
            headers: headers,
            receive_timeout: 5_000
          )
      end

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status, body: resp}} ->
        Logger.warning("MediaMTX API #{method} #{path} -> #{status}: #{inspect(resp)}")
        {:error, {:http, status, resp}}

      {:error, reason} ->
        Logger.warning("MediaMTX API #{method} #{path} failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
