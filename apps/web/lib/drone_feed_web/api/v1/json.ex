defmodule DroneFeedWeb.Api.V1.JSON do
  @moduledoc false

  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Accounts.User
  alias DroneFeed.Flights.Flight
  alias DroneFeed.Streaming
  alias DroneFeed.Streaming.LiveSession

  def user(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      role: user.role
    }
  end

  def flight(%Flight{} = flight, %Scope{} = scope) do
    base = %{
      id: flight.id,
      type: "flight",
      name: flight.name,
      slug: flight.slug,
      original_video_name: flight.original_video_name,
      publishing: flight.publishing,
      expires_at: flight.expires_at,
      inserted_at: flight.inserted_at,
      owner: owner(flight.user)
    }

    if flight.publishing do
      Map.put(base, :urls, public_flight_urls(Streaming.flight_urls(flight)))
    else
      Map.put(base, :urls, nil)
    end
    |> maybe_mark_owned(scope, flight)
  end

  def live_session(%LiveSession{} = session, %Scope{} = scope) do
    owned? = Streaming.owns?(scope, session)

    base = %{
      id: session.id,
      type: "live",
      name: session.name,
      ingest_mode: session.ingest_mode,
      publishing: session.publishing,
      active: session.active,
      inserted_at: session.inserted_at,
      owner: owner(session.user),
      owned: owned?
    }

    urls = Streaming.urls(session)

    cond do
      session.publishing ->
        Map.merge(base, %{
          urls: public_live_urls(urls),
          ingest: if(owned?, do: ingest_urls(urls), else: nil)
        })

      owned? ->
        Map.merge(base, %{
          urls: nil,
          ingest: ingest_urls(urls)
        })

      true ->
        Map.merge(base, %{urls: nil, ingest: nil})
    end
  end

  def feed_item(%Flight{} = flight, scope), do: flight(flight, scope)
  def feed_item(%LiveSession{} = session, scope), do: live_session(session, scope)

  defp owner(%User{} = user), do: %{id: user.id, email: user.email}
  defp owner(_), do: nil

  defp maybe_mark_owned(map, scope, flight) do
    Map.put(map, :owned, DroneFeed.Flights.owns?(scope, flight))
  end

  defp public_flight_urls(urls) do
    Map.take(urls, [
      :primary_pull,
      :primary_pull_alt,
      :primary_protocol,
      :primary_note,
      :srt_pull,
      :srt_pull_alt,
      :rtmp_pull,
      :rtmp_pull_alt,
      :rtsp_pull,
      :rtsp_pull_alt,
      :media_ip,
      :media_domain,
      :srt_url,
      :klv_url
    ])
  end

  defp public_live_urls(urls) do
    Map.take(urls, [
      :hls_pull,
      :rtmp_pull,
      :rtmp_pull_alt,
      :rtsp_pull,
      :rtsp_pull_alt,
      :srt_pull,
      :srt_pull_alt,
      :media_ip,
      :media_domain
    ])
  end

  defp ingest_urls(urls) do
    Map.take(urls, [
      :ingest_mode,
      :rtmp_ingest,
      :rtmp_ingest_alt,
      :rtmp_dji_server,
      :rtmp_dji_server_alt,
      :rtmp_dji_key,
      :rtsp_ingest,
      :udp_ingest,
      :udp_ingest_alt,
      :udp_port
    ])
  end
end
