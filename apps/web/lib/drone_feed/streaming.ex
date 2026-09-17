defmodule DroneFeed.Streaming do
  @moduledoc """
  Live ingest sessions for companion-app RTMP/RTSP publish.
  """

  import Ecto.Query

  alias DroneFeed.Accounts.Scope
  alias DroneFeed.MediaURLs
  alias DroneFeed.Repo
  alias DroneFeed.Streaming.LiveSession

  def list_live_sessions(%Scope{user: user}) do
    LiveSession
    |> where([s], s.user_id == ^user.id and s.active == true)
    |> order_by([s], desc: s.inserted_at)
    |> Repo.all()
  end

  def get_live_session!(%Scope{user: user}, id) do
    LiveSession
    |> where([s], s.id == ^id and s.user_id == ^user.id)
    |> Repo.one!()
  end

  def get_live_session(id) when is_binary(id), do: Repo.get(LiveSession, id)

  def create_live_session(%Scope{user: user}, attrs) do
    %LiveSession{}
    |> LiveSession.changeset(
      Map.merge(attrs, %{
        "user_id" => user.id,
        "stream_key" => generate_stream_key(),
        "active" => true
      })
    )
    |> Repo.insert()
  end

  def end_live_session(%Scope{} = scope, id) do
    session = get_live_session!(scope, id)

    session
    |> LiveSession.changeset(%{"active" => false})
    |> Repo.update()
  end

  def change_live_session(%LiveSession{} = session, attrs \\ %{}) do
    LiveSession.changeset(session, attrs)
  end

  def urls(%LiveSession{} = session) do
    ip = MediaURLs.media_ip()
    domain = MediaURLs.media_domain()

    %{
      media_ip: ip,
      media_domain: domain,
      rtmp_ingest:
        MediaURLs.rtmp_url(:live, session.id,
          host: ip,
          include_key: true,
          stream_key: session.stream_key
        ),
      rtsp_ingest:
        MediaURLs.rtsp_url(:live, session.id,
          host: ip,
          include_key: true,
          stream_key: session.stream_key
        ),
      rtmp_pull: MediaURLs.rtmp_url(:live, session.id, host: ip),
      rtsp_pull: MediaURLs.rtsp_url(:live, session.id, host: ip),
      rtmp_pull_alt: alt_url(domain, &MediaURLs.rtmp_url(:live, session.id, host: &1)),
      rtsp_pull_alt: alt_url(domain, &MediaURLs.rtsp_url(:live, session.id, host: &1)),
      stream_key: session.stream_key
    }
  end

  def flight_urls(flight) do
    ip = MediaURLs.media_ip()
    domain = MediaURLs.media_domain()

    %{
      media_ip: ip,
      media_domain: domain,
      # Primary: STANAG-style MPEG-TS with MISB KLV / data (after mux) — IP:port by default
      primary_pull: MediaURLs.rtsp_url(:vod, flight.id, host: ip),
      primary_pull_alt: alt_url(domain, &MediaURLs.rtsp_url(:vod, flight.id, host: &1)),
      primary_protocol: "rtsp",
      primary_note: "FMV + telemetry/geo (MISB KLV in-band)",
      # Secondary: video-only for simple players
      rtmp_pull: MediaURLs.rtmp_url(:vod, flight.id, host: ip),
      rtmp_pull_alt: alt_url(domain, &MediaURLs.rtmp_url(:vod, flight.id, host: &1)),
      rtmp_note: "video/audio only (no KLV in FLV)",
      rtsp_pull: MediaURLs.rtsp_url(:vod, flight.id, host: ip),
      rtsp_pull_alt: alt_url(domain, &MediaURLs.rtsp_url(:vod, flight.id, host: &1)),
      stream_key: flight.stream_key
    }
    |> maybe_put_metadata(flight, :srt_path, "srt")
    |> maybe_put_metadata(flight, :klv_path, "klv")
  end

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
