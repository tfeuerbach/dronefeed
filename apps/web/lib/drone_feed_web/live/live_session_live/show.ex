defmodule DroneFeedWeb.LiveSessionLive.Show do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Streaming

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--theater">
      <div class="df-flight-page">
        <header class="df-flight-header">
          <div class="min-w-0 space-y-1.5">
            <a
              href={~p"/flights"}
              class="text-sm text-base-content/50 transition-colors hover:text-base-content"
            >
              ← Flights
            </a>
            <div class="flex flex-wrap items-center gap-3">
              <span :if={@session.publishing} class="df-live-dot" title="Public feed"></span>
              <h1 class="truncate text-2xl font-semibold tracking-tight sm:text-3xl">
                {@session.name}
              </h1>
              <span class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[10px] uppercase text-base-content/50">
                {if @session.ingest_mode == "udp_mpegts", do: "udp", else: "push"}
              </span>
            </div>
            <p class="font-mono text-xs text-base-content/50">
              Live ingest
              <span :if={@session.user}> · {@session.user.email}</span>
            </p>
          </div>

          <div class="df-flight-header-actions">
            <label :if={@owner?} class="df-publish-toggle">
              <span>Public feed</span>
              <input
                type="checkbox"
                class="toggle toggle-primary"
                checked={@session.publishing}
                phx-click="toggle_publish"
              />
            </label>
            <p :if={!@owner? and @session.publishing} class="text-sm text-base-content/50">
              Public · pull endpoints below
            </p>
            <button
              :if={@can_end?}
              type="button"
              class="btn btn-warning btn-sm"
              phx-click="end_live"
              data-confirm="End this live session?"
            >
              End session
            </button>
          </div>
        </header>

        <div class="df-flight-deck df-live-deck">
          <section class="df-flight-stage">
            <div
              :if={@session.publishing}
              id={"live-preview-#{@session.id}"}
              class="df-flight-player"
              phx-hook="LiveHlsPreview"
              phx-update="ignore"
              data-hls-url={@urls.hls_pull}
              data-user="drone"
              data-pass={@session.stream_key}
            >
              <video
                id={"live-video-#{@session.id}"}
                class="df-flight-video"
                muted
                autoplay
                playsinline
                controls
              >
              </video>
              <p class="df-live-preview-status" data-live-status hidden></p>
            </div>
            <div
              :if={!@session.publishing}
              class="df-flight-player flex items-center justify-center bg-base-200/40"
            >
              <p class="max-w-md px-6 text-center text-sm text-base-content/60">
                <%= if @owner? do %>
                  Enable <span class="font-medium">Public feed</span>
                  to allow researchers to pull and to show the in-browser preview.
                  You can still push from the phone / encoder using the ingest URLs below.
                <% else %>
                  Public feed is off — pull endpoints are not available yet.
                <% end %>
              </p>
            </div>
            <p :if={@session.publishing} class="mt-2 text-xs text-base-content/50">
              In-browser preview uses low-latency HLS (typically a few seconds behind; phone
              keyframe interval sets a floor). Research tools should pull RTSP/SRT for lower delay.
              Phone RTMP is video/AAC only — no map telemetry on this path.
            </p>
          </section>

          <section class="df-flight-urls df-panel space-y-3">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              Connect / pull
            </h2>
            <.stream_pull_urls urls={@urls} kind={:live} show_pull={@session.publishing} />
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    case Streaming.fetch_active_live_session(scope, id) do
      {:ok, session} ->
        {:ok,
         socket
         |> assign(:page_title, session.name)
         |> assign(:session, session)
         |> assign(:urls, Streaming.urls(session))
         |> assign(:owner?, Streaming.owns?(scope, session))
         |> assign(:can_end?, Streaming.can_end?(scope, session))}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Live session not found or already ended")
         |> push_navigate(to: ~p"/flights")}
    end
  end

  @impl true
  def handle_event("toggle_publish", _params, socket) do
    scope = socket.assigns.current_scope
    session = socket.assigns.session

    case Streaming.set_publishing(scope, session.id, !session.publishing) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:session, updated)
         |> assign(:urls, Streaming.urls(updated))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the session owner can change public feed access")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not update public feed: #{inspect(reason)}")}
    end
  end

  def handle_event("end_live", _params, socket) do
    scope = socket.assigns.current_scope

    case Streaming.end_live_session(scope, socket.assigns.session.id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Live session ended")
         |> push_navigate(to: ~p"/flights")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the session owner or an admin can end it")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not end session: #{inspect(reason)}")}
    end
  end
end
