defmodule DroneFeedWeb.Layouts do
  @moduledoc """
  Application layouts for DroneFeed.
  """
  use DroneFeedWeb, :html

  embed_templates "layouts/*"

  attr :flash, :map, required: true
  attr :current_scope, :map, default: nil
  attr :main_class, :string, default: nil
  slot :inner_block, required: true

  def app(assigns) do
    assigns =
      assign_new(assigns, :admin_unread, fn ->
        user = assigns[:current_scope] && assigns.current_scope.user

        if user && DroneFeed.Accounts.User.admin?(user) do
          DroneFeed.Accounts.count_unread_admin_notifications()
        else
          0
        end
      end)

    ~H"""
    <div class="df-shell">
      <header class="df-nav">
        <div class="mx-auto flex max-w-5xl items-center justify-between gap-4 px-4 py-3 sm:px-6">
          <a
            href={if(@current_scope, do: ~p"/flights", else: ~p"/")}
            class="df-brand flex items-center gap-2.5"
          >
            <img
              src={~p"/images/brand-mark.svg"}
              width="28"
              height="28"
              alt=""
              class="df-brand-mark-img"
            />
            <span>DroneFeed</span>
          </a>

          <nav class="flex items-center gap-1 sm:gap-2">
            <%= if @current_scope do %>
              <a href={~p"/flights"} class="btn btn-ghost btn-sm font-medium">
                Flights
              </a>
              <a href={~p"/flights/public"} class="btn btn-ghost btn-sm font-medium">
                Public Feeds
              </a>

              <div class="mx-1 hidden h-4 w-px bg-base-content/15 sm:block" />

              <.link
                navigate={~p"/users/settings"}
                class="btn btn-ghost btn-sm max-w-[11rem] truncate font-medium"
                title="Account settings"
              >
                {DroneFeed.Accounts.User.display_name(@current_scope.user)}
              </.link>
              <.link
                :if={DroneFeed.Accounts.User.admin?(@current_scope.user)}
                navigate={~p"/admin"}
                class="btn btn-ghost btn-sm font-medium"
              >
                Admin
                <span
                  :if={@admin_unread > 0}
                  class="ml-1 inline-flex min-w-[1.1rem] items-center justify-center rounded bg-primary px-1 text-[10px] font-bold text-primary-content"
                >
                  {@admin_unread}
                </span>
              </.link>
              <.link href={~p"/users/log-out"} method="delete" class="btn btn-ghost btn-sm">
                Log out
              </.link>
            <% else %>
              <.link navigate={~p"/users/request-access"} class="btn btn-ghost btn-sm">
                Request access
              </.link>
              <.link navigate={~p"/users/log-in"} class="btn btn-primary btn-sm">Log in</.link>
            <% end %>
            <.theme_toggle />
          </nav>
        </div>
      </header>

      <main class={["df-main", @main_class]}>
        <div class="df-page df-page-shown">
          {render_slot(@inner_block)}
        </div>
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :flash, :map, required: true
  attr :id, :string, default: "flash-group"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  def theme_toggle(assigns) do
    ~H"""
    <div class="ml-1 flex overflow-hidden rounded-md border border-base-content/10">
      <button
        type="button"
        class="px-2 py-1.5 text-base-content/50 hover:bg-base-200 hover:text-base-content [[data-theme=signal]_&]:bg-base-200 [[data-theme=signal]_&]:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="signal"
        title="Light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-3.5" />
      </button>
      <button
        type="button"
        class="px-2 py-1.5 text-base-content/50 hover:bg-base-200 hover:text-base-content [[data-theme=signal-dark]_&]:bg-base-200 [[data-theme=signal-dark]_&]:text-base-content"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="signal-dark"
        title="Dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-3.5" />
      </button>
    </div>
    """
  end
end
