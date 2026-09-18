defmodule DroneFeed.Streaming do
  @moduledoc """
  Live ingest sessions: companion RTMP/RTSP push, or drone MPEG-TS over UDP.

  Active sessions are a shared library (like recorded flights). Creating and
  ending a session stays with the owner.
  """

  import Ecto.Query
  require Logger

  alias DroneFeed.Accounts.Scope
  alias DroneFeed.MediaURLs
  alias DroneFeed.Repo
  alias DroneFeed.Streaming.LiveSession
  alias DroneFeed.Streaming.MediaMTX
  alias DroneFeed.Streaming.UdpPorts

  @doc """
  Lists all active live sessions (shared library).
  """
  def list_live_sessions(%Scope{}) do
    LiveSession
    |> where([s], s.active == true)
    |> order_by([s], desc: s.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Active live sessions with Public feed on (shared gallery).
  """
  def list_published_live_sessions(%Scope{}) do
    LiveSession
    |> where([s], s.active == true and s.publishing == true)
    |> order_by([s], desc: s.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  def get_live_session!(%Scope{}, id) do
    LiveSession
    |> where([s], s.id == ^id)
    |> preload(:user)
    |> Repo.one!()
  end

  def get_live_session(id) when is_binary(id), do: Repo.get(LiveSession, id)

  @doc """
  Fetches an active live session for the shared library detail page.
  """
  def fetch_active_live_session(%Scope{}, id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} ->
        case LiveSession
             |> where([s], s.id == ^id and s.active == true)
             |> preload(:user)
             |> Repo.one() do
          nil -> {:error, :not_found}
          session -> {:ok, session}
        end

      :error ->
        {:error, :not_found}
    end
  end

  def owns?(%Scope{user: %{id: user_id}}, %LiveSession{user_id: user_id}), do: true
  def owns?(_, _), do: false

  @doc """
  Session owners may end their own live feeds; admins may end any.
  """
  def can_end?(%Scope{user: %{role: "admin"}}, %LiveSession{}), do: true
  def can_end?(%Scope{} = scope, %LiveSession{} = session), do: owns?(scope, session)

  @doc """
  Owner-only Public feed toggle for live sessions.

  When off, MediaMTX still accepts drone **publish**, but **read/playback**
  (SRT/RTSP/RTMP/HLS pull) is denied — same shape as recorded flights.
  """
  def set_publishing(%Scope{} = scope, session_id, publishing) when is_boolean(publishing) do
    session = get_live_session!(scope, session_id)

    cond do
      not owns?(scope, session) ->
        {:error, :forbidden}

      not session.active ->
        {:error, :inactive}

      true ->
        session
        |> LiveSession.publish_changeset(publishing)
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, Repo.preload(updated, :user)}
          other -> other
        end
    end
  end

  def create_live_session(%Scope{user: user}, attrs) do
    mode = ingest_mode_from_attrs(attrs)

    with {:ok, port_attrs} <- udp_attrs_for_mode(mode) do
      Repo.transaction(fn ->
        insert_attrs =
          attrs
          |> Map.put("user_id", user.id)
          |> Map.put("stream_key", generate_stream_key())
          |> Map.put("active", true)
          |> Map.put("publishing", false)
          |> Map.put("ingest_mode", mode)
          |> Map.merge(port_attrs)

        case %LiveSession{} |> LiveSession.changeset(insert_attrs) |> Repo.insert() do
          {:ok, session} ->
            case provision_ingest(session) do
              :ok ->
                Repo.preload(session, :user)

              {:error, reason} ->
                UdpPorts.release(session.udp_port)
                Repo.rollback(reason)
            end

          {:error, changeset} ->
            UdpPorts.release(Map.get(port_attrs, "udp_port"))
            Repo.rollback(changeset)
        end
      end)
    else
      {:error, :udp_ports_exhausted} = err ->
        err

      {:error, _} = err ->
        err
    end
  end

  def end_live_session(%Scope{} = scope, id) do
    session = get_live_session!(scope, id)

    if can_end?(scope, session) do
      _ = teardown_ingest(session)
      port = session.udp_port

      case session
           |> LiveSession.changeset(%{"active" => false, "udp_port" => nil})
           |> Repo.update() do
        {:ok, _ended} = ok ->
          UdpPorts.release(port)
          ok

        other ->
          other
      end
    else
      {:error, :forbidden}
    end
  end

  def change_live_session(%LiveSession{} = session, attrs \\ %{}) do
    LiveSession.changeset(session, attrs)
  end

  @doc """
  Re-apply MediaMTX UDP listeners for active `udp_mpegts` sessions after boot.
  """
  def restore_udp_ingest do
    LiveSession
    |> where([s], s.active == true and s.ingest_mode == "udp_mpegts" and not is_nil(s.udp_port))
    |> Repo.all()
    |> Enum.each(fn session ->
      case provision_ingest(session) do
        :ok ->
          Logger.info("Restored UDP ingest for live/#{session.id} on :#{session.udp_port}")

        {:error, reason} ->
          Logger.error(
            "Failed to restore UDP ingest for live/#{session.id}: #{inspect(reason)}"
          )
      end
    end)
  end

  def urls(%LiveSession{} = session) do
    ip = MediaURLs.media_ip()
    domain = MediaURLs.media_domain()

    key_opts = [include_key: true, stream_key: session.stream_key]

    base = %{
      media_ip: ip,
      media_domain: domain,
      ingest_mode: session.ingest_mode,
      hls_pull: MediaURLs.hls_browser_url(:live, session.id),
      rtmp_pull: MediaURLs.rtmp_url(:live, session.id, [host: ip] ++ key_opts),
      rtsp_pull: MediaURLs.rtsp_url(:live, session.id, [host: ip] ++ key_opts),
      srt_pull: MediaURLs.srt_mpegts_url(:live, session.id, [host: ip] ++ key_opts),
      rtmp_pull_alt:
        alt_url(domain, fn h -> MediaURLs.rtmp_url(:live, session.id, [host: h] ++ key_opts) end),
      rtsp_pull_alt:
        alt_url(domain, fn h -> MediaURLs.rtsp_url(:live, session.id, [host: h] ++ key_opts) end),
      srt_pull_alt:
        alt_url(domain, fn h ->
          MediaURLs.srt_mpegts_url(:live, session.id, [host: h] ++ key_opts)
        end)
    }

    case session.ingest_mode do
      "udp_mpegts" ->
        Map.merge(base, %{
          udp_ingest: MediaURLs.udp_mpegts_url(session.udp_port, host: ip),
          udp_ingest_alt: alt_url(domain, &MediaURLs.udp_mpegts_url(session.udp_port, host: &1)),
          udp_port: session.udp_port,
          rtmp_ingest: nil,
          rtsp_ingest: nil
        })

      _ ->
        Map.merge(base, %{
          # Phone / DJI Custom RTMP — query-auth URL (single paste field).
          rtmp_ingest: MediaURLs.rtmp_url_query(:live, session.id, session.stream_key, host: ip),
          rtmp_ingest_alt:
            alt_url(domain, fn h ->
              MediaURLs.rtmp_url_query(:live, session.id, session.stream_key, host: h)
            end),
          # Two-field DJI dialog (Server URL + Stream Key).
          rtmp_dji_server: MediaURLs.rtmp_dji_server(host: ip),
          rtmp_dji_server_alt: alt_url(domain, &MediaURLs.rtmp_dji_server(host: &1)),
          rtmp_dji_key: MediaURLs.rtmp_dji_stream_key(session.id, session.stream_key),
          rtsp_ingest:
            MediaURLs.rtsp_url(:live, session.id,
              host: ip,
              include_key: true,
              stream_key: session.stream_key
            ),
          udp_ingest: nil,
          udp_ingest_alt: nil,
          udp_port: nil
        })
    end
  end

  def flight_urls(flight) do
    ip = MediaURLs.media_ip()
    domain = MediaURLs.media_domain()

    %{
      media_ip: ip,
      media_domain: domain,
      primary_pull:
        MediaURLs.srt_mpegts_url(:vod, flight.id,
          host: ip,
          include_key: true,
          stream_key: flight.stream_key
        ),
      primary_pull_alt:
        alt_url(domain, fn h ->
          MediaURLs.srt_mpegts_url(:vod, flight.id,
            host: h,
            include_key: true,
            stream_key: flight.stream_key
          )
        end),
      primary_protocol: "srt",
      primary_note: "MPEG-TS over SRT (H.264 + MISB KLV)",
      srt_pull:
        MediaURLs.srt_mpegts_url(:vod, flight.id,
          host: ip,
          include_key: true,
          stream_key: flight.stream_key
        ),
      srt_pull_alt:
        alt_url(domain, fn h ->
          MediaURLs.srt_mpegts_url(:vod, flight.id,
            host: h,
            include_key: true,
            stream_key: flight.stream_key
          )
        end),
      rtmp_pull:
        MediaURLs.rtmp_url(:vod, flight.id,
          host: ip,
          include_key: true,
          stream_key: flight.stream_key
        ),
      rtmp_pull_alt:
        alt_url(domain, fn h ->
          MediaURLs.rtmp_url(:vod, flight.id,
            host: h,
            include_key: true,
            stream_key: flight.stream_key
          )
        end),
      rtmp_note: "video/audio only (FLV cannot carry KLV)",
      rtsp_pull:
        MediaURLs.rtsp_url(:vod, flight.id,
          host: ip,
          include_key: true,
          stream_key: flight.stream_key
        ),
      rtsp_pull_alt:
        alt_url(domain, fn h ->
          MediaURLs.rtsp_url(:vod, flight.id,
            host: h,
            include_key: true,
            stream_key: flight.stream_key
          )
        end),
      rtsp_note: "H.264 + KLV as RTP/SMPTE336M (not MPEG-TS-in-RTSP)"
    }
    |> maybe_put_metadata(flight, :srt_path, "srt")
    |> maybe_put_metadata(flight, :klv_path, "klv")
  end

  defp provision_ingest(%LiveSession{ingest_mode: "udp_mpegts", id: id, udp_port: port})
       when is_integer(port) do
    MediaMTX.add_udp_mpegts_path("live/#{id}", port)
  end

  defp provision_ingest(%LiveSession{ingest_mode: "push"}), do: :ok
  defp provision_ingest(_), do: {:error, :invalid_ingest}

  defp teardown_ingest(%LiveSession{ingest_mode: "udp_mpegts", id: id}) do
    MediaMTX.delete_path("live/#{id}")
  end

  defp teardown_ingest(_), do: :ok

  defp ingest_mode_from_attrs(attrs) do
    mode = Map.get(attrs, "ingest_mode") || Map.get(attrs, :ingest_mode) || "push"
    if mode in LiveSession.ingest_modes(), do: mode, else: "push"
  end

  defp udp_attrs_for_mode("udp_mpegts") do
    case UdpPorts.allocate() do
      {:ok, port} -> {:ok, %{"udp_port" => port}}
      {:error, _} = err -> err
    end
  end

  defp udp_attrs_for_mode(_), do: {:ok, %{"udp_port" => nil}}

  defp alt_url(nil, _fun), do: nil
  defp alt_url(domain, fun), do: fun.(domain)

  defp maybe_put_metadata(urls, flight, field, kind) do
    case Map.get(flight, field) do
      path when is_binary(path) and path != "" ->
        Map.put(
          urls,
          String.to_atom("#{kind}_url"),
          MediaURLs.metadata_url(flight.id, kind, flight.stream_key)
        )

      _ ->
        urls
    end
  end

  defp generate_stream_key do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
