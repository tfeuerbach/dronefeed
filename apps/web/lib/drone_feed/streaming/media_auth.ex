defmodule DroneFeed.Streaming.MediaAuth do
  @moduledoc """
  Authorizes MediaMTX HTTP auth hook requests for publish/read actions.
  """

  alias DroneFeed.Flights
  alias DroneFeed.Streaming
  alias DroneFeed.Streaming.FlightLog

  @doc """
  Returns `:ok` when access is allowed, `{:error, reason}` otherwise.

  Expects MediaMTX auth payload keys as string or atom maps.
  """
  def authorize(payload) when is_map(payload) do
    action = get(payload, "action")
    path = get(payload, "path") || ""
    {user, password} = credentials(payload)

    result =
      if user == "" and password == "" and action in ["publish", "read", "playback"] do
        {:error, :unauthorized}
      else
        do_authorize(action, path, password)
      end

    log_auth(payload, result)
    result
  end

  defp do_authorize(action, path, password) when action in ["publish", "read", "playback"] do
    case parse_path(path) do
      {:vod, id} -> authorize_vod(action, id, password)
      {:live, id} -> authorize_live(action, id, password)
      :unknown -> {:error, :forbidden}
    end
  end

  defp do_authorize(_action, _path, _password), do: {:error, :forbidden}

  defp authorize_vod(action, id, password) do
    case fetch_flight(id) do
      %{publishing: true, stream_key: ^password} when action in ["publish", "read", "playback"] ->
        :ok

      %{publishing: true} ->
        {:error, :forbidden}

      %{publishing: false} ->
        {:error, :forbidden}

      nil ->
        {:error, :forbidden}
    end
  end

  defp authorize_live(action, id, password) do
    case fetch_live_session(id) do
      # Drone / encoder may publish into an active session before Public feed is on.
      %{active: true, stream_key: ^password} when action == "publish" ->
        :ok

      %{active: true, publishing: true, stream_key: ^password}
      when action in ["read", "playback"] ->
        :ok

      %{active: true, publishing: false} when action in ["read", "playback"] ->
        {:error, :forbidden}

      %{active: true} ->
        {:error, :forbidden}

      %{active: false} ->
        {:error, :forbidden}

      nil ->
        {:error, :forbidden}
    end
  end

  # Invalid IDs must not raise Ecto cast errors (Phoenix maps those to HTTP 400,
  # which MediaMTX surfaces as a confusing RTMP "Bad Request").
  defp fetch_flight(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> Flights.get_flight(id)
      :error -> nil
    end
  end

  defp fetch_live_session(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> Streaming.get_live_session(id)
      :error -> nil
    end
  end

  # MediaMTX puts RTMP `?user=&pass=` into user/password; also accept query
  # fallback so phone Custom RTMP stays authable if a client only fills `query`.
  defp credentials(payload) do
    user = stringify(get(payload, "user"))
    password = stringify(get(payload, "password") || get(payload, "token"))

    if user != "" or password != "" do
      {user, password}
    else
      query = stringify(get(payload, "query"))
      params = URI.decode_query(query)

      {
        stringify(Map.get(params, "user")),
        stringify(Map.get(params, "pass") || Map.get(params, "password") || Map.get(params, "token"))
      }
    end
  end

  defp stringify(nil), do: ""
  defp stringify(value) when is_binary(value), do: String.trim(value)
  defp stringify(value), do: value |> to_string() |> String.trim()

  defp log_auth(payload, result) do
    path = get(payload, "path") || ""
    action = get(payload, "action") || "?"
    protocol = get(payload, "protocol") || "?"
    ip = get(payload, "ip") || "?"
    user = get(payload, "user") || ""
    ua = get(payload, "userAgent") || get(payload, "user_agent") || ""

    case parse_path(path) do
      {:vod, flight_id} ->
        empty_probe? = user == "" and (get(payload, "password") || "") == ""

        {level, verdict} =
          case result do
            :ok ->
              {:info, "ALLOWED"}

            {:error, :unauthorized} when empty_probe? ->
              {:debug, "PROBE (empty credentials — client will retry with auth)"}

            {:error, reason} ->
              {:warn, "DENIED (#{reason})"}
          end

        msg =
          "#{verdict} #{action} via #{protocol} from #{ip}" <>
            if(ua != "", do: " ua=#{String.slice(to_string(ua), 0, 80)}", else: "")

        FlightLog.append(flight_id, level, :auth, msg, %{
          action: action,
          protocol: protocol,
          ip: ip,
          path: path
        })

      _ ->
        :ok
    end
  end

  defp parse_path(path) do
    path = String.trim_leading(path, "/")

    case String.split(path, "/", parts: 2) do
      ["vod", id] when byte_size(id) > 0 -> {:vod, id}
      ["live", id] when byte_size(id) > 0 -> {:live, id}
      _ -> :unknown
    end
  end

  defp get(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        try do
          Map.get(map, String.to_existing_atom(key))
        rescue
          ArgumentError -> nil
        end
    end
  end
end
