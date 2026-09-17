defmodule DroneFeedWeb.UserLive.RequestAccess do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="df-auth mx-auto max-w-lg space-y-6">
        <.header>
          Request an account
          <:subtitle>
            Submit your details for administrator review. After approval you will receive
            an email to verify your address before you can log in or upload flights.
          </:subtitle>
        </.header>

        <div class="df-panel space-y-4">
          <.form
            for={@form}
            id="account_request_form"
            phx-change="validate"
            phx-submit="save"
            class="space-y-3"
          >
            <div class="grid gap-3 sm:grid-cols-2">
              <.input
                field={@form[:first_name]}
                type="text"
                label="First name"
                required
                autocomplete="given-name"
              />
              <.input
                field={@form[:last_name]}
                type="text"
                label="Last name"
                required
                autocomplete="family-name"
              />
            </div>
            <.input field={@form[:email]} type="email" label="Email" required autocomplete="email" />
            <.input
              field={@form[:organization]}
              type="text"
              label="Organization"
              required
              autocomplete="organization"
            />
            <.input
              field={@form[:location]}
              type="text"
              label="Location"
              required
              autocomplete="address-level2"
              placeholder="City, country or lab site"
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              required
              autocomplete="new-password"
              phx-debounce="blur"
            />
            <.input
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              required
              autocomplete="new-password"
            />
            <.button class="btn btn-primary w-full" phx-disable-with="Submitting…">
              Submit request
            </.button>
          </.form>
        </div>

        <p class="text-center text-sm text-base-content/60">
          Already approved?
          <.link navigate={~p"/users/log-in"} class="font-medium text-primary hover:underline">
            Log in
          </.link>
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:ok, push_navigate(socket, to: ~p"/flights")}
    else
      changeset = Accounts.change_account_request(%{}, hash_password: false)

      {:ok,
       socket
       |> assign(:page_title, "Request an account")
       |> assign(:form, to_form(changeset, as: :user))}
    end
  end

  @impl true
  def handle_event("validate", %{"user" => params}, socket) do
    changeset =
      Accounts.change_account_request(params, hash_password: false)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset, as: :user))}
  end

  def handle_event("save", %{"user" => params}, socket) do
    case Accounts.request_account(params, fn -> url(~p"/admin") end) do
      {:ok, %User{}} ->
        {:noreply,
         socket
         |> put_flash(
           :info,
           "Request submitted. An administrator will review it; you will receive a verification email after approval."
         )
         |> push_navigate(to: ~p"/users/log-in")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset, as: :user))}
    end
  end
end
