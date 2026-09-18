defmodule DroneFeedWeb.UserLive.Verify do
  use DroneFeedWeb, :live_view

  alias DroneFeed.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-main--auth">
      <div class="df-auth space-y-4 text-center">
        <.header>
          {@heading}
          <:subtitle>{@message}</:subtitle>
        </.header>

        <.link :if={@ok? == true} navigate={~p"/users/log-in"} class="btn btn-primary">
          Continue to log in
        </.link>
        <.link :if={@ok? == false} navigate={~p"/users/log-in"} class="btn btn-primary">
          Go to log in
        </.link>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Verifying…")
      |> assign(:ok?, nil)
      |> assign(:heading, "Verifying your email")
      |> assign(:message, "One moment…")

    # LiveView mounts twice (HTTP then websocket). Confirm only when connected
    # so the one-time token is not consumed by the disconnected render — and so
    # email link scanners that only GET the page cannot burn the token.
    if connected?(socket) do
      confirm(socket, token)
    else
      {:ok, socket}
    end
  end

  defp confirm(socket, token) do
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
         |> assign(:page_title, "Verification")
         |> assign(:ok?, false)
         |> assign(:heading, "Link already used or expired")
         |> assign(
           :message,
           "This verification link is no longer valid. If an administrator already approved you, try logging in — your account may already be verified."
         )}
    end
  end
end
