defmodule DroneFeedWeb.FlightLive.Published do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Flights
  alias DroneFeed.Streaming

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--wide">
      <.header>
        Public Feeds
        <:subtitle>
          Flights with egress on — anyone with the URL and stream key can pull
          RTMP/RTSP from this host (worldwide once deployed).
        </:subtitle>
      </.header>

      <div :if={@flights == []} class="df-panel mt-8 text-sm text-base-content/60">
        No Public Feeds right now. Open a flight and turn on
        <span class="font-medium text-base-content/80">Public feed</span>
        to start MediaMTX egress.
      </div>

      <div id="public-gallery" class="df-gallery mt-8">
        <.link
          :for={flight <- @flights}
          navigate={~p"/flights/#{flight.id}"}
          id={"public-#{flight.id}"}
          class="df-gallery-card group"
        >
          <div class="df-gallery-media">
            <video
              class="df-gallery-video"
              muted
              playsinline
              preload="metadata"
              src={~p"/flights/#{flight.id}/media"}
            >
            </video>
            <span class="df-gallery-live">
              <span class="df-live-dot"></span>
              Public
            </span>
          </div>
          <div class="df-gallery-meta">
            <p class="truncate font-medium group-hover:text-primary">{flight.name}</p>
            <p class="truncate font-mono text-xs text-base-content/50">
              {flight.original_video_name}
            </p>
            <p :if={flight.user} class="truncate text-xs text-base-content/45">
              {flight.user.email}
            </p>
            <% urls = Streaming.flight_urls(flight) %>
            <p class="mt-2 truncate font-mono text-[0.7rem] text-base-content/55">
              {urls.rtmp_pull}
            </p>
            <p
              :if={urls.rtmp_pull_alt}
              class="truncate font-mono text-[0.65rem] text-base-content/40"
            >
              alt {urls.rtmp_pull_alt}
            </p>
          </div>
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Public Feeds")
     |> assign(:flights, Flights.list_published_flights(scope))}
  end
end
