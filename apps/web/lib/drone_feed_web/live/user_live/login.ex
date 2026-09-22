defmodule DroneFeedWeb.UserLive.Login do
  use DroneFeedWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--auth">
      <div class="df-auth space-y-4">
        <.header>
          Log in
          <:subtitle>
            <%= if @current_scope do %>
              Reauthenticate to continue.
            <% else %>
              <%= if @show_dev_login_hint do %>
                Local default: <span class="font-mono text-sm">admin@localhost</span> /
                <span class="font-mono text-sm">admin</span>
              <% else %>
                Sign in to your DroneFeed instance.
              <% end %>
            <% end %>
          </:subtitle>
        </.header>

        <div class="df-panel df-auth-panel space-y-4">
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
            class="space-y-3"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              autocomplete="username"
              spellcheck="false"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="current-password"
              spellcheck="false"
            />
            <.button class="btn btn-primary w-full" name={@form[:remember_me].name} value="true">
              Log in
            </.button>
          </.form>
        </div>

        <p :if={!@current_scope} class="df-auth-footer text-center text-sm text-base-content/60">
          Need access?
          <.link navigate={~p"/users/request-access"} class="font-medium text-primary hover:underline">
            Request an account
          </.link>
          <span class="df-auth-footer-extra">
            · Forgot credentials? Contact
            <span class="font-medium text-base-content/80">{@admin_contact}</span>
          </span>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok,
     socket
     |> assign(:form, form)
     |> assign(:trigger_submit, false)
     |> assign(:page_title, "Log in")
     |> assign(:show_dev_login_hint, Application.get_env(:drone_feed, :show_dev_login_hint, false))
     |> assign(
       :admin_contact,
       Application.get_env(:drone_feed, :admin_contact, "your system administrator")
     )}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end
end
