defmodule DroneFeedWeb.FlightLive.Index do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Flights
  alias DroneFeed.Flights.Flight
  alias DroneFeed.Streaming
  alias DroneFeed.Streaming.LiveSession

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Flights
        <:subtitle>
          Upload a recording or start a live ingest session. Turn on
          <span class="font-medium">Public feed</span>
          on recordings for SRT/RTSP with telemetry. Live phone RTMP is video-only.
        </:subtitle>
      </.header>

      <div class="df-reveal mt-8 space-y-10">
        <section class="df-panel df-reveal-item space-y-4" style="--df-i: 0">
          <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
            <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
              Add flight
            </h2>
            <div class="df-mode-toggle inline-flex overflow-hidden rounded-md border border-base-content/15">
              <button
                type="button"
                class={mode_btn_class(@create_mode == :upload)}
                phx-click="set_create_mode"
                phx-value-mode="upload"
              >
                Upload recording
              </button>
              <button
                type="button"
                class={mode_btn_class(@create_mode == :live)}
                phx-click="set_create_mode"
                phx-value-mode="live"
              >
                Live ingest
              </button>
            </div>
          </div>

          <div :if={@create_mode == :upload} class="space-y-4">
            <p class="text-sm text-base-content/60">
              FMV / MP4 / TS plus optional SRT or KLV telemetry. Files stay in the shared library for
              {@retention_days} days. Drag and drop into a zone or use Choose file.
            </p>
            <.form
              for={@form}
              id="flight-form"
              phx-submit="save"
              phx-change="validate"
              class="relative space-y-4"
            >
              <.input field={@form[:name]} type="text" label="Name" required />
              <.upload_dropzone
                upload={@uploads.video}
                label="Video (FMV / MP4 / TS)"
                hint="Required — drag and drop or choose a file"
              />
              <div class="grid gap-4 sm:grid-cols-2">
                <.upload_dropzone
                  upload={@uploads.srt}
                  label="Telemetry (.srt)"
                  hint="Consumer drone metadata — optional"
                />
                <.upload_dropzone
                  upload={@uploads.klv}
                  label="KLV"
                  hint="Enterprise metadata sidecar — optional if already in the TS"
                />
              </div>
              <.button
                phx-disable-with="Saving…"
                variant="primary"
                disabled={not upload_ready?(@uploads)}
              >
                Upload flight
              </.button>

              <div
                class={[
                  "df-upload-overlay",
                  uploads_busy?(@uploads) && "df-upload-overlay--on"
                ]}
                id="flight-upload-overlay"
                aria-live="polite"
              >
                <div class="df-upload-card">
                  <p class="df-upload-card-title">
                    {upload_phase_title(@uploads)}
                  </p>
                  <p class="df-upload-card-sub">
                    {upload_phase_sub(@uploads)}
                  </p>
                  <div :if={uploads_busy?(@uploads)} class="df-upload-card-list">
                    <.upload_progress_entry
                      :for={entry <- upload_entries(@uploads)}
                      entry={entry}
                    />
                  </div>
                  <div class="df-upload-indeterminate" aria-hidden="true"></div>
                </div>
              </div>
            </.form>
          </div>

          <div :if={@create_mode == :live} class="space-y-4">
            <p class="text-sm text-base-content/60">
              Companion push (RTMP/RTSP) or drone MPEG-TS over UDP. Research tools pull the same
              RTMP/RTSP URLs either way.
            </p>
            <.form
              for={@live_form}
              id="live-session-form"
              phx-submit="create_live"
              phx-change="validate_live"
              class="space-y-4"
            >
              <.input field={@live_form[:name]} type="text" label="Session name" required />
              <.input
                field={@live_form[:ingest_mode]}
                type="select"
                label="Ingest"
                options={[
                  {"Phone / DJI Custom RTMP (video only)", "push"},
                  {"Encoder UDP (MPEG-TS + optional KLV)", "udp_mpegts"}
                ]}
              />
              <p class="text-xs text-base-content/55">
                Mavic / Mini / Air: choose phone RTMP — open DJI Fly → livestream → Custom RTMP and
                paste the session URL. Needs LTE/5G or Starlink on the phone. No telemetry on this
                path; upload MP4 + .SRT after landing for map/KLV.
              </p>
              <.button phx-disable-with="Creating..." variant="primary">Start live session</.button>
            </.form>
          </div>
        </section>

        <section :if={@sessions != []} class="df-reveal-item space-y-4" style="--df-i: 1">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-base-content/50">
            Live sessions
          </h2>
          <ul id="live-sessions" class="space-y-3">
            <li
              :for={session <- @sessions}
              id={"live-session-#{session.id}"}
              class="df-panel"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 flex-1 space-y-1">
                  <div
                    :if={@renaming_session_id != session.id}
                    class="flex flex-wrap items-center gap-2"
                  >
                    <span
                      :if={session.publishing}
                      class="df-live-dot"
                      title="Public feed"
                    >
                    </span>
                    <.link
                      navigate={~p"/live/#{session.id}"}
                      class="truncate font-medium hover:text-primary"
                    >
                      {session.name}
                    </.link>
                    <span class="rounded bg-base-200 px-1.5 py-0.5 font-mono text-[10px] uppercase text-base-content/50">
                      {if session.ingest_mode == "udp_mpegts", do: "udp", else: "push"}
                    </span>
                  </div>
                  <form
                    :if={@renaming_session_id == session.id}
                    id={"rename-live-#{session.id}"}
                    phx-submit="rename_live"
                    class="flex flex-wrap items-center gap-2"
                  >
                    <input type="hidden" name="session_id" value={session.id} />
                    <input
                      type="text"
                      name="name"
                      value={session.name}
                      required
                      maxlength="200"
                      class="input input-bordered input-sm w-full max-w-xs"
                      phx-mounted={JS.focus()}
                    />
                    <.button type="submit" variant="primary" class="btn-sm">Save</.button>
                    <button
                      type="button"
                      class="btn btn-ghost btn-sm"
                      phx-click="cancel_rename_live"
                    >
                      Cancel
                    </button>
                  </form>
                  <p :if={session.user} class="text-xs text-base-content/45">
                    Started by {session.user.email}
                  </p>
                </div>
                <div class="flex items-center gap-2">
                  <.link navigate={~p"/live/#{session.id}"} class="btn btn-ghost btn-sm">
                    Open
                  </.link>
                  <button
                    :if={Streaming.can_rename?(@current_scope, session)}
                    type="button"
                    class="btn btn-ghost btn-sm"
                    phx-click="start_rename_live"
                    phx-value-id={session.id}
                  >
                    Rename
                  </button>
                  <label
                    :if={Streaming.owns?(@current_scope, session)}
                    class="flex cursor-pointer items-center gap-2 text-sm"
                  >
                    <span class="text-base-content/70">Public feed</span>
                    <input
                      type="checkbox"
                      class="toggle toggle-primary toggle-sm"
                      checked={session.publishing}
                      phx-click="toggle_live_publish"
                      phx-value-id={session.id}
                    />
                  </label>
                  <button
                    :if={Streaming.can_end?(@current_scope, session)}
                    type="button"
                    class="btn btn-warning btn-sm"
                    phx-click="end_live"
                    phx-value-id={session.id}
                    data-confirm="End this live session?"
                  >
                    End
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </section>

        <section class="df-reveal-item space-y-4" style="--df-i: 2">
          <div :if={@flights == [] and @sessions == []} class="df-panel text-sm text-base-content/60">
            No recordings yet. Upload a flight or start a live session above.
          </div>
          <div :if={@flights == [] and @sessions != []} class="df-panel text-sm text-base-content/60">
            No recordings yet. Live sessions are listed above.
          </div>
          <ul id="flights" class="space-y-3">
            <li :for={flight <- @flights} id={"flight-#{flight.id}"} class="df-panel">
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0 space-y-1">
                  <div class="flex items-center gap-2">
                    <span :if={flight.publishing} class="df-live-dot" title="Public feed"></span>
                    <.link
                      navigate={~p"/flights/#{flight.id}"}
                      class="truncate font-medium hover:text-primary"
                    >
                      {flight.name}
                    </.link>
                  </div>
                  <p class="font-mono text-xs text-base-content/50">
                    Expires {Calendar.strftime(flight.expires_at, "%Y-%m-%d %H:%M UTC")}
                    · {flight.original_video_name}
                  </p>
                  <p :if={flight.user} class="text-xs text-base-content/45">
                    Uploaded by {flight.user.email}
                  </p>
                </div>
                <div class="flex items-center gap-3">
                  <.link navigate={~p"/flights/#{flight.id}"} class="btn btn-ghost btn-sm">
                    Open
                  </.link>
                  <label
                    :if={Flights.owns?(@current_scope, flight)}
                    class="flex cursor-pointer items-center gap-2 text-sm"
                  >
                    <span class="text-base-content/70">Public feed</span>
                    <input
                      type="checkbox"
                      class="toggle toggle-primary toggle-sm"
                      checked={flight.publishing}
                      phx-click="toggle_publish"
                      phx-value-id={flight.id}
                    />
                  </label>
                  <button
                    :if={Flights.can_delete?(@current_scope, flight)}
                    type="button"
                    class="btn btn-ghost btn-sm text-error"
                    phx-click="delete"
                    phx-value-id={flight.id}
                    data-confirm="Delete this flight?"
                  >
                    Delete
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  defp mode_btn_class(true),
    do: "px-3 py-1.5 text-sm font-medium bg-primary text-primary-content"

  defp mode_btn_class(false),
    do: "px-3 py-1.5 text-sm font-medium text-base-content/70 hover:bg-base-200"

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:page_title, "Flights")
     |> assign(:create_mode, :upload)
     |> assign(:renaming_session_id, nil)
     |> assign(:retention_days, Application.get_env(:drone_feed, :retention_days, 5))
     |> assign(:flights, Flights.list_flights(scope))
     |> assign(:sessions, Streaming.list_live_sessions(scope))
     |> assign(:form, to_form(Flights.change_flight(%Flight{})))
     |> assign(:live_form, to_form(Streaming.change_live_session(%LiveSession{})))
     |> allow_upload(:video,
       accept: :any,
       max_entries: 1,
       max_file_size: 5_000_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> allow_upload(:srt,
       accept: :any,
       max_entries: 1,
       max_file_size: 50_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )
     |> allow_upload(:klv,
       accept: :any,
       max_entries: 1,
       max_file_size: 500_000_000,
       auto_upload: true,
       progress: &handle_progress/3
     )}
  end

  defp handle_progress(_name, _entry, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_create_mode", %{"mode" => mode}, socket)
      when mode in ~w(upload live) do
    {:noreply, assign(socket, :create_mode, String.to_existing_atom(mode))}
  end

  def handle_event("validate", %{"flight" => params}, socket) do
    form =
      %Flight{}
      |> Flights.change_flight(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, form: form)}
  end

  def handle_event("validate_live", %{"live_session" => params}, socket) do
    form =
      %LiveSession{}
      |> Streaming.change_live_session(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, live_form: form)}
  end

  def handle_event("save", %{"flight" => params}, socket) do
    scope = socket.assigns.current_scope

    video_entries = consume_uploaded_entries(socket, :video, &localize/2)
    srt_entries = consume_uploaded_entries(socket, :srt, &localize/2)
    klv_entries = consume_uploaded_entries(socket, :klv, &localize/2)

    files =
      case video_entries do
        [video | _] ->
          %{
            video: video,
            srt: List.first(srt_entries),
            klv: List.first(klv_entries)
          }

        [] ->
          nil
      end

    case files do
      nil ->
        {:noreply, put_flash(socket, :error, "Video file is required")}

      files ->
        case Flights.create_flight(scope, params, files) do
          {:ok, flight} ->
            {:noreply,
             socket
             |> put_flash(:info, "Flight uploaded")
             |> push_navigate(to: ~p"/flights/#{flight.id}")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, form: to_form(changeset))}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Upload failed: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("create_live", %{"live_session" => params}, socket) do
    scope = socket.assigns.current_scope

    case Streaming.create_live_session(scope, params) do
      {:ok, session} ->
        {:noreply,
         socket
         |> put_flash(:info, "Live session created")
         |> push_navigate(to: ~p"/live/#{session.id}")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, live_form: to_form(changeset))}

      {:error, :udp_ports_exhausted} ->
        {:noreply,
         put_flash(socket, :error, "No free UDP ingest ports — end an idle UDP session or widen the range")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start live session: #{inspect(reason)}")}
    end
  end

  def handle_event("end_live", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Streaming.end_live_session(scope, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:renaming_session_id, nil)
         |> assign(sessions: Streaming.list_live_sessions(scope))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the session owner or an admin can end it")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not end session: #{inspect(reason)}")}
    end
  end

  def handle_event("start_rename_live", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    session = Streaming.get_live_session!(scope, id)

    if Streaming.can_rename?(scope, session) do
      {:noreply, assign(socket, :renaming_session_id, id)}
    else
      {:noreply, put_flash(socket, :error, "Only an admin can rename live sessions")}
    end
  end

  def handle_event("cancel_rename_live", _params, socket) do
    {:noreply, assign(socket, :renaming_session_id, nil)}
  end

  def handle_event("rename_live", %{"session_id" => id, "name" => name}, socket) do
    scope = socket.assigns.current_scope

    case Streaming.rename_live_session(scope, id, name) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:renaming_session_id, nil)
         |> assign(sessions: Streaming.list_live_sessions(scope))
         |> put_flash(:info, "Live session renamed")}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only an admin can rename live sessions")}

      {:error, %Ecto.Changeset{} = changeset} ->
        msg =
          changeset
          |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
          |> Map.get(:name, ["invalid name"])
          |> List.first()

        {:noreply, put_flash(socket, :error, "Could not rename: #{msg}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not rename: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_live_publish", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    session = Streaming.get_live_session!(scope, id)

    case Streaming.set_publishing(scope, id, !session.publishing) do
      {:ok, _} ->
        {:noreply, assign(socket, sessions: Streaming.list_live_sessions(scope))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the session owner can change public feed access")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not update public feed: #{inspect(reason)}")
         |> assign(sessions: Streaming.list_live_sessions(scope))}
    end
  end

  def handle_event("toggle_publish", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope
    flight = Flights.get_flight!(scope, id)

    case Flights.set_publishing(scope, id, !flight.publishing) do
      {:ok, _} ->
        {:noreply, assign(socket, flights: Flights.list_flights(scope))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the uploader can change public feed access")}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Could not start public feed: #{inspect(reason)}")
         |> assign(flights: Flights.list_flights(scope))}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Flights.delete_flight(scope, id) do
      {:ok, _} ->
        {:noreply, assign(socket, flights: Flights.list_flights(scope))}

      {:error, :forbidden} ->
        {:noreply, put_flash(socket, :error, "Only the uploader or an admin can delete this flight")}
    end
  end

  defp localize(meta, entry) do
    tmp = Path.join(System.tmp_dir!(), "#{entry.uuid}-#{entry.client_name}")
    File.cp!(meta.path, tmp)
    {:ok, %{path: tmp, filename: entry.client_name}}
  end

  defp uploads_busy?(uploads) do
    Enum.any?(upload_entries(uploads), fn entry -> not entry.done? end) or
      Enum.any?(upload_entries(uploads), & &1.progress < 100)
  end

  defp upload_ready?(uploads) do
    case uploads.video.entries do
      [entry] -> entry.done? and entry.valid?
      _ -> false
    end
  end

  defp upload_phase_title(uploads) do
    if uploads_busy?(uploads), do: "Uploading files", else: "Processing flight"
  end

  defp upload_phase_sub(uploads) do
    if uploads_busy?(uploads) do
      "Transferring to the server — keep this tab open."
    else
      "Storing files and preparing browser preview / library entry…"
    end
  end

  defp upload_entries(uploads) do
    [:video, :srt, :klv]
    |> Enum.flat_map(fn key -> Map.get(uploads, key).entries end)
  end

  defp upload_dropzone(assigns) do
    assigns = assign_new(assigns, :hint, fn -> nil end)

    ~H"""
    <div class="df-dropzone space-y-2" phx-drop-target={@upload.ref}>
      <label class="label py-0">
        <span class="label-text">{@label}</span>
      </label>
      <p :if={@hint} class="text-xs text-base-content/50">{@hint}</p>
      <.live_file_input upload={@upload} class="file-input file-input-bordered w-full" />
      <.upload_progress_entry :for={entry <- @upload.entries} entry={entry} />
      <p :for={err <- upload_errors(@upload)} class="text-sm text-error">
        {error_to_string(err)}
      </p>
    </div>
    """
  end

  defp upload_progress_entry(assigns) do
    pct = assigns.entry.progress |> max(0) |> min(100)

    assigns =
      assigns
      |> assign(:pct, pct)
      |> assign(:done?, pct >= 100)

    ~H"""
    <div class="df-upload-entry">
      <div class="df-upload-entry-meta">
        <span class="df-upload-entry-name" title={@entry.client_name}>{@entry.client_name}</span>
        <span class="df-upload-entry-pct">
          <%= if @done? do %>
            Ready
          <% else %>
            {@pct}%
          <% end %>
        </span>
      </div>
      <div
        class="df-upload-track"
        role="progressbar"
        aria-valuemin="0"
        aria-valuemax="100"
        aria-valuenow={@pct}
        aria-label={"Upload progress for #{@entry.client_name}"}
      >
        <div
          class={["df-upload-fill", @done? && "df-upload-fill--done"]}
          style={"width: #{@pct}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  defp error_to_string(:too_large), do: "file too large"
  defp error_to_string(:too_many_files), do: "too many files"
  defp error_to_string(:not_accepted), do: "unacceptable file type"
  defp error_to_string(err), do: inspect(err)
end
