defmodule DroneFeedWeb.CoreComponents do
  @moduledoc """
  Provides core UI components.

  At first glance, this module may seem daunting, but its goal is to provide
  core building blocks for your application, such as tables, forms, and
  inputs. The components consist mostly of markup and are well-documented
  with doc strings and declarative assigns. You may customize and style
  them in any way you want, based on your application growth and needs.

  The foundation for styling is Tailwind CSS, a utility-first CSS framework,
  augmented with daisyUI, a Tailwind CSS plugin that provides UI components
  and themes. Here are useful references:

    * [daisyUI](https://daisyui.com/docs/intro/) - a good place to get
      started and see the available components.

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component
  use Gettext, backend: DroneFeedWeb.Gettext

  alias Phoenix.LiveView.JS

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="toast toast-top toast-end z-50"
      {@rest}
    >
      <div class={[
        "alert w-80 sm:w-96 max-w-80 sm:max-w-96 text-wrap",
        @kind == :info && "alert-info",
        @kind == :error && "alert-error"
      ]}>
        <.icon :if={@kind == :info} name="hero-information-circle" class="size-5 shrink-0" />
        <.icon :if={@kind == :error} name="hero-exclamation-circle" class="size-5 shrink-0" />
        <div>
          <p :if={@title} class="font-semibold">{@title}</p>
          <p>{msg}</p>
        </div>
        <div class="flex-1" />
        <button type="button" class="group self-start cursor-pointer" aria-label={gettext("close")}>
          <.icon name="hero-x-mark" class="size-5 opacity-40 group-hover:opacity-70" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  ## Examples

      <.button>Send!</.button>
      <.button phx-click="go" variant="primary">Send!</.button>
      <.button navigate={~p"/"}>Home</.button>
  """
  attr :rest, :global, include: ~w(href navigate patch method download name value disabled)
  attr :class, :any
  attr :variant, :string, values: ~w(primary)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    variants = %{"primary" => "btn-primary", nil => "btn-primary btn-soft"}

    assigns =
      assign_new(assigns, :class, fn ->
        ["btn", Map.fetch!(variants, assigns[:variant])]
      end)

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file location month number password
               search select tel text textarea time url week hidden)

  attr :field, Phoenix.HTML.FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %Phoenix.HTML.FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Phoenix.HTML.Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <span class="label">
          <input
            type="checkbox"
            id={@id}
            name={@name}
            value="true"
            checked={@checked}
            class={@class || "checkbox checkbox-sm"}
            {@rest}
          />{@label}
        </span>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || "w-full select", @errors != [] && (@error_class || "select-error")]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Phoenix.HTML.Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || "w-full textarea",
            @errors != [] && (@error_class || "textarea-error")
          ]}
          {@rest}
        >{Phoenix.HTML.Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "password"} = assigns) do
    ~H"""
    <div class="fieldset mb-2" id={"#{@id}-wrap"} phx-hook="PasswordReveal" data-revealed="false">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <div class="df-password-field relative">
          <input
            type="password"
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value("password", @value)}
            class={[
              @class || "w-full input df-password-input",
              @errors != [] && (@error_class || "input-error")
            ]}
            {@rest}
          />
          <button
            type="button"
            class="df-password-reveal"
            data-password-reveal
            aria-label="Show password"
            aria-pressed="false"
            title="Show password"
          >
            <span class="df-password-reveal__show" aria-hidden="true">
              <.icon name="hero-eye" class="size-4" />
            </span>
            <span class="df-password-reveal__hide" aria-hidden="true">
              <.icon name="hero-eye-slash" class="size-4" />
            </span>
          </button>
        </div>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "location"} = assigns) do
    places_json = Jason.encode!(DroneFeed.Locations.all())
    list_id = "#{assigns.id}-suggestions"
    assigns = assign(assigns, places_json: places_json, list_id: list_id)

    ~H"""
    <div class="fieldset mb-2">
      <%!-- Ignore LV patches so validate/re-render does not remount the typeahead. --%>
      <div
        id={"#{@id}-wrap"}
        phx-hook="LocationSuggest"
        phx-update="ignore"
        data-places={@places_json}
        class="df-location-wrap"
      >
        <label for={@id}>
          <span :if={@label} class="label mb-1">{@label}</span>
        </label>
        <div class="df-location-field relative">
          <input
            type="text"
            name={@name}
            id={@id}
            value={Phoenix.HTML.Form.normalize_value("text", @value)}
            role="combobox"
            aria-autocomplete="list"
            aria-expanded="false"
            aria-controls={@list_id}
            data-location-input
            phx-debounce="200"
            class={[
              @class || "w-full input",
              @errors != [] && (@error_class || "input-error")
            ]}
            {@rest}
          />
          <ul
            id={@list_id}
            class="df-location-list"
            role="listbox"
            data-location-list
            hidden
          >
          </ul>
        </div>
      </div>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="fieldset mb-2">
      <label for={@id}>
        <span :if={@label} class="label mb-1">{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Phoenix.HTML.Form.normalize_value(@type, @value)}
          class={[
            @class || "w-full input",
            @errors != [] && (@error_class || "input-error")
          ]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p class="mt-1.5 flex gap-2 items-center text-sm text-error">
      <.icon name="hero-exclamation-circle" class="size-5" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-center justify-between gap-6", "pb-4"]}>
      <div>
        <h1 class="text-lg font-semibold leading-8">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="text-sm text-base-content/70">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="table table-zebra">
      <thead>
        <tr>
          <th :for={col <- @col}>{col[:label]}</th>
          <th :if={@action != []}>
            <span class="sr-only">{gettext("Actions")}</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr :for={row <- @rows} id={@row_id && @row_id.(row)}>
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={@row_click && "hover:cursor-pointer"}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 font-semibold">
            <div class="flex gap-4">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="list">
      <li :for={item <- @item} class="list-row">
        <div class="list-col-grow">
          <div class="font-bold">{item.title}</div>
          <div>{render_slot(item)}</div>
        </div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Renders pull / ingest URLs. Access is capability-URL only (token embedded in the URL);
  no separate username/password fields.
  """
  attr :urls, :map, required: true
  attr :kind, :atom, default: :flight, values: [:flight, :live]

  def stream_pull_urls(assigns) do
    ~H"""
    <div class="df-panel-muted space-y-1">
      <p class="text-xs text-base-content/45">
        Connect via IP:port
        <span class="font-mono text-base-content/70">{@urls.media_ip}</span>
        <span :if={@urls.media_domain}>
          · domain alternate <span class="font-mono text-base-content/70">{@urls.media_domain}</span>
        </span>
      </p>
      <%= if @kind == :flight do %>
        <p class="text-primary">
          <span class="text-base-content/50">Primary SRT MPEG-TS (H.264+KLV)</span> {@urls.primary_pull}
        </p>
        <p :if={@urls.primary_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.primary_pull_alt}
        </p>
        <p><span class="text-base-content/50">RTSP</span> {@urls.rtsp_pull}</p>
        <p :if={@urls.rtsp_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.rtsp_pull_alt}
        </p>
        <p class="text-xs text-base-content/45">
          RTSP carries H.264 + KLV as RTP/SMPTE336M (not MPEG-TS-in-RTSP). Prefer SRT for STANAG tools.
        </p>
        <p><span class="text-base-content/50">RTMP video-only</span> {@urls.rtmp_pull}</p>
        <p :if={@urls.rtmp_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.rtmp_pull_alt}
        </p>
        <p :if={@urls[:srt_url]}>
          <span class="text-base-content/50">source .srt sidecar</span> {@urls.srt_url}
        </p>
        <p :if={@urls[:klv_url]}>
          <span class="text-base-content/50">source .klv sidecar</span> {@urls.klv_url}
        </p>
      <% else %>
        <%= if @urls[:udp_ingest] do %>
          <p class="text-primary">
            <span class="text-base-content/50">UDP MPEG-TS ingest</span> {@urls.udp_ingest}
          </p>
          <p :if={@urls[:udp_ingest_alt]} class="text-base-content/70">
            <span class="text-base-content/45">alt</span> {@urls.udp_ingest_alt}
          </p>
          <p class="text-xs text-base-content/45">
            Point the drone / encoder at this address (MPEG-TS over UDP). No token on the wire —
            treat the port as a secret and restrict source IPs in the security group when possible.
          </p>
        <% else %>
          <div class="space-y-2 rounded-md border border-primary/25 bg-primary/5 p-3">
            <p class="text-sm font-medium text-primary">Phone → Custom RTMP (DJI Fly / GO)</p>
            <ol class="list-decimal space-y-1 pl-4 text-xs text-base-content/70">
              <li>On the remote, open the camera view → share / livestream → <strong>Custom RTMP</strong>.</li>
              <li>Paste the URL below (or use Server + Stream key if the app has two fields).</li>
              <li>Start livestream. Phone needs LTE/5G or Starlink — video only, no .SRT/KLV.</li>
            </ol>
            <p class="break-all font-mono text-xs text-base-content/90">
              <span class="text-base-content/50">RTMP URL</span> {@urls.rtmp_ingest}
            </p>
            <p :if={@urls[:rtmp_ingest_alt]} class="break-all font-mono text-[0.7rem] text-base-content/60">
              <span class="text-base-content/45">alt</span> {@urls.rtmp_ingest_alt}
            </p>
            <div class="space-y-1 border-t border-base-content/10 pt-2">
              <p class="text-[0.7rem] uppercase tracking-wide text-base-content/45">
                Two-field apps (Server + Stream key)
              </p>
              <p class="break-all font-mono text-xs">
                <span class="text-base-content/50">Server</span> {@urls.rtmp_dji_server}
              </p>
              <p
                :if={@urls[:rtmp_dji_server_alt]}
                class="break-all font-mono text-[0.7rem] text-base-content/60"
              >
                <span class="text-base-content/45">alt</span> {@urls.rtmp_dji_server_alt}
              </p>
              <p class="break-all font-mono text-xs">
                <span class="text-base-content/50">Stream key</span> {@urls.rtmp_dji_key}
              </p>
            </div>
            <p class="text-xs text-base-content/50">
              Advanced: RTSP publish <span class="font-mono">{@urls.rtsp_ingest}</span>
            </p>
          </div>
        <% end %>
        <p class="pt-1 text-[0.7rem] font-semibold uppercase tracking-wide text-base-content/45">
          Researchers pull (video)
        </p>
        <p>
          <span class="text-base-content/50">RTSP pull</span> {@urls.rtsp_pull}
        </p>
        <p :if={@urls.rtsp_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.rtsp_pull_alt}
        </p>
        <p><span class="text-base-content/50">RTMP pull</span> {@urls.rtmp_pull}</p>
        <p :if={@urls.rtmp_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.rtmp_pull_alt}
        </p>
        <p><span class="text-base-content/50">SRT pull</span> {@urls.srt_pull}</p>
        <p :if={@urls.srt_pull_alt} class="text-base-content/70">
          <span class="text-base-content/45">alt</span> {@urls.srt_pull_alt}
        </p>
        <p class="text-xs text-base-content/45">
          Live phone push is H.264/AAC only — no map telemetry until you upload MP4 + .SRT after landing.
        </p>
      <% end %>
      <p class="text-xs text-base-content/45">
        Paste the full URL into your tool — access is embedded (treat like a secret link).
      </p>
    </div>
    """
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # When using gettext, we typically pass the strings we want
    # to translate as a static argument:
    #
    #     # Translate the number of files with plural rules
    #     dngettext("errors", "1 file", "%{count} files", count)
    #
    # However the error messages in our forms and APIs are generated
    # dynamically, so we need to translate them by calling Gettext
    # with our gettext backend as first argument. Translations are
    # available in the errors.po file (as we use the "errors" domain).
    if count = opts[:count] do
      Gettext.dngettext(DroneFeedWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(DroneFeedWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
