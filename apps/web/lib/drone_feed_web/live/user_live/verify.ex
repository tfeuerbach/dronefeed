defmodule DroneFeedWeb.UserLive.Verify do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="df-auth mx-auto max-w-md space-y-6 text-center">
        <.header>
          {@heading}
          <:subtitle>{@message}</:subtitle>
        </.header>

        <.link :if={@ok?} navigate={~p"/users/log-in"} class="btn btn-primary">
          Continue to log in
        </.link>
        <.link :if={!@ok?} navigate={~p"/users/log-in"} class="btn btn-ghost">
          Back to log in
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    login_url = url(~p"/users/log-in")

    case Accounts.confirm_user(token, login_url) do
      {:ok, _user} ->
        {:ok,
         socket
         |> assign(:page_title, "Email verified")
         |> assign(:ok?, true)
         |> assign(:heading, "Email verified")
         |> assign(
           :message,
           "Your account is approved and verified. You can log in and upload flights."
         )}

      {:error, _} ->
        {:ok,
         socket
         |> assign(:page_title, "Verification failed")
         |> assign(:ok?, false)
         |> assign(:heading, "Link invalid or expired")
         |> assign(
           :message,
           "This verification link is invalid or has expired. Contact an administrator if you still need access."
         )}
    end
  end
end
