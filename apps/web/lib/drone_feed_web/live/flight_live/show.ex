defmodule DroneFeedWeb.FlightLive.Show do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Flights
  alias DroneFeed.Streaming
  alias DroneFeed.Streaming.FlightLog
  alias DroneFeed.Telemetry

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--theater">
      <div class="df-flight-page">
        <header class="df-flight-header">
          <div class="min-w-0 space-y-1.5">
            <.link
              navigate={~p"/flights"}
              class="text-sm text-base-content/50 transition-colors hover:text-base-content"
            >
              ← Flights
            </.link>
            <div class="flex flex-wrap items-center gap-3">
              <span :if={@flight.publishing} class="df-live-dot" title="Public feed"></span>
              <h1 class="truncate text-2xl font-semibold tracking-tight sm:text-3xl">
                {@flight.name}
              </h1>
            </div>
            <p class="font-mono text-xs text-base-content/50">
              {@flight.original_video_name}
              · expires {Calendar.strftime(@flight.expires_at, "%Y-%m-%d %H:%M UTC")}
              <span :if={@flight.user}> · {@flight.user.email}</span>
            </p>
          </div>

          <div class="df-flight-header-actions">
            <label :if={@owner?} class="df-publish-toggle">
              <span>Public feed</span>
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={@flight.publishing}
                phx-click="toggle_publish"
              />
            </label>
            <p :if={!@owner? and @flight.publishing} class="text-sm text-base-content/50">
              Public · pull endpoints below
            </p>
          </div>
        </header>

        <div
          id={"flight-deck-#{@flight.id}"}
          class="df-flight-deck"
          phx-hook="FlightDeck"
          data-points={Jason.encode!(@telemetry.points)}
        >
          <section class="df-flight-stage">
            <div class="df-flight-player">
              <video
                id={"flight-video-#{@flight.id}"}
                class="df-flight-video"
                controls
                playsinline
                preload="metadata"
                src={~p"/flights/#{@flight.id}/media"}
              >
              </video>
            </div>
          </section>

          <aside class="df-flight-side">
            <section class="df-panel df-flight-readouts">
              <div class="df-flight-side-head">
                <h2>Live readouts</h2>
                <p>
                  {source_label(@telemetry.source)}
                  <span :if={@telemetry.all_count > 0}>· {@telemetry.all_count} samples</span>
                </p>
              </div>
              <div class="df-gauge-grid">
                <div class="df-gauge">
                  <p class="df-gauge-label">Latitude</p>
                  <p class="df-gauge-value" data-gauge="lat">{fmt_coord(@readout.lat)}</p>
                </div>
                <div class="df-gauge">
                  <p class="df-gauge-label">Longitude</p>
                  <p class="df-gauge-value" data-gauge="lon">{fmt_coord(@readout.lon)}</p>
                </div>
                <div class="df-gauge">
                  <p class="df-gauge-label">Altitude</p>
                  <p class="df-gauge-value" data-gauge="alt">{fmt_alt(@readout.alt)}</p>
                </div>
              </div>
              <p :if={@telemetry.message} class="text-sm text-base-content/60">{@telemetry.message}</p>
            </section>

            <section class="df-panel df-flight-map-panel">
              <div class="df-flight-side-head df-flight-side-head--pad">
                <h2>Map View</h2>
              </div>
              <div id={"flight-map-#{@flight.id}"} class="df-flight-map" data-map-root></div>
            </section>
          </aside>

          <section class="df-flight-raw df-panel !p-0 overflow-hidden">
            <div class="df-flight-band-head">
              <div>
                <h2>Raw telemetry</h2>
                <p>Sidecar dump · formatted cue below tracks playback</p>
              </div>
            </div>
            <pre class="df-flight-raw-body">{@telemetry.raw_preview}</pre>
            <div class="df-flight-raw-live">
              <p data-raw-line>Waiting for playback…</p>
            </div>
          </section>

          <section :if={@flight.publishing} class="df-flight-urls df-panel space-y-3">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              Public pull endpoints
            </h2>
            <.stream_pull_urls urls={Streaming.flight_urls(@flight)} kind={:flight} />
          </section>

          <section class="df-flight-terminal df-panel !p-0 overflow-hidden">
            <div class="df-flight-band-head">
              <div>
                <h2>Publish console</h2>
                <p>Mux · FFmpeg · MediaMTX auth / third-party pull attempts</p>
              </div>
              <div class="flex flex-wrap items-center gap-2">
                <div class="join join-horizontal">
                  <button
                    type="button"
                    class={["btn btn-xs join-item", @log_filter == :all && "btn-active"]}
                    phx-click="log_filter"
                    phx-value-filter="all"
                  >
                    All
                  </button>
                  <button
                    type="button"
                    class={["btn btn-xs join-item", @log_filter == :info && "btn-active"]}
                    phx-click="log_filter"
                    phx-value-filter="info"
                  >
                    Info+
                  </button>
                  <button
                    type="button"
                    class={["btn btn-xs join-item", @log_filter == :warn && "btn-active"]}
                    phx-click="log_filter"
                    phx-value-filter="warn"
                  >
                    Warn+
                  </button>
                </div>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs"
                  phx-click="clear_logs"
                  data-confirm="Clear publish console for this flight?"
                >
                  Clear
                </button>
              </div>
            </div>
            <div
              id={"flight-log-wrap-#{@flight.id}"}
              class="df-terminal"
              phx-hook="FlightTerminal"
            >
              <div id={"flight-log-#{@flight.id}"} phx-update="stream">
                <div
                  :for={{dom_id, entry} <- @streams.log_entries}
                  id={dom_id}
                  class={["df-terminal-line", "df-terminal-#{entry.level}"]}
                >
                  <span class="df-terminal-ts">{fmt_ts(entry.at)}</span>
                  <span class="df-terminal-lvl">{entry.level}</span>
                  <span class="df-terminal-src">[{entry.source}]</span>
                  <span class="df-terminal-msg">{entry.message}</span>
                </div>
              </div>
              <div :if={@log_empty?} id="flight-log-empty" class="df-terminal-line df-terminal-info">
                <span class="df-terminal-msg text-base-content/50">
                  <%= if @flight.publishing do %>
                    Waiting for mux / FFmpeg / connection events…
                  <% else %>
                    Enable Public feed to start the publisher and capture connection logs.
                  <% end %>
                </span>
              </div>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope
    flight = Flights.get_flight!(scope, id)
    telemetry = Telemetry.for_flight(flight)
    stats = telemetry.stats

    if connected?(socket) do
      FlightLog.subscribe(flight.id)
    end

    entries = FlightLog.list(flight.id)

    {:ok,
     socket
     |> assign(:page_title, flight.name)
     |> assign(:flight, flight)
     |> assign(:owner?, Flights.owns?(scope, flight))
     |> assign(:telemetry, telemetry)
     |> assign(:readout, %{lat: stats.lat, lon: stats.lon, alt: stats.alt})
     |> assign(:log_filter, :all)
     |> assign(:log_empty?, entries == [])
     |> stream(:log_entries, entries, reset: true)}
  end

  @impl true
  def handle_event("toggle_publish", _params, socket) do
    scope = socket.assigns.current_scope
    flight = socket.assigns.flight

    case Flights.set_publishing(scope, flight.id, !flight.publishing) do
      {:ok, updated} ->
        entries = FlightLog.list(updated.id, min_level: min_level(socket.assigns.log_filter))

        {:noreply,
         socket
         |> assign(flight: updated, log_empty?: entries == [])
         |> stream(:log_entries, entries, reset: true)}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the uploader can change public feed access")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start public feed: #{inspect(reason)}")}
    end
  end

  def handle_event("clear_logs", _params, socket) do
    FlightLog.clear(socket.assigns.flight.id)

    {:noreply,
     socket
     |> assign(:log_empty?, true)
     |> stream(:log_entries, [], reset: true)}
  end

  def handle_event("log_filter", %{"filter" => filter}, socket) do
    filter = filter_atom(filter)
    entries = FlightLog.list(socket.assigns.flight.id, min_level: min_level(filter))

    {:noreply,
     socket
     |> assign(log_filter: filter, log_empty?: entries == [])
     |> stream(:log_entries, entries, reset: true)}
  end

  @impl true
  def handle_info({:flight_log, entry}, socket) do
    if visible?(entry, socket.assigns.log_filter) do
      {:noreply,
       socket
       |> assign(:log_empty?, false)
       |> stream_insert(:log_entries, entry)}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:flight_log_cleared, _}, socket) do
    {:noreply,
     socket
     |> assign(:log_empty?, true)
     |> stream(:log_entries, [], reset: true)}
  end

  defp visible?(_entry, :all), do: true
  defp visible?(entry, :info), do: entry.level in [:info, :warn, :error]
  defp visible?(entry, :warn), do: entry.level in [:warn, :error]
  defp visible?(_, _), do: true

  defp min_level(:all), do: :debug
  defp min_level(:info), do: :info
  defp min_level(:warn), do: :warn
  defp min_level(_), do: :debug

  defp filter_atom("info"), do: :info
  defp filter_atom("warn"), do: :warn
  defp filter_atom(_), do: :all

  defp fmt_ts(%DateTime{} = dt) do
    Calendar.strftime(dt, "%H:%M:%S.") <>
      (dt.microsecond |> elem(0) |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0"))
  end

  defp fmt_ts(_), do: "—"

  defp fmt_coord(nil), do: "—"
  defp fmt_coord(v) when is_float(v), do: :erlang.float_to_binary(v, decimals: 6)
  defp fmt_coord(v), do: to_string(v)

  defp fmt_alt(nil), do: "—"
  defp fmt_alt(v) when is_float(v), do: "#{:erlang.float_to_binary(v, decimals: 1)} m"
  defp fmt_alt(v), do: "#{v} m"

  defp source_label(:srt), do: "DJI .SRT"
  defp source_label(:klv), do: "MISB KLV"
  defp source_label(_), do: "none"
end
