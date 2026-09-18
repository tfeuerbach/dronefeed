defmodule DroneFeedWeb.HomeLive do
  use DroneFeedWeb, :live_view

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} main_class="df-home-main">
      <section class="df-home relative overflow-hidden">
        <div class="df-home-hero relative mx-auto flex max-w-5xl flex-col justify-center gap-10 px-4 py-16 sm:px-6">
          <div class="max-w-2xl space-y-5">
            <img
              src={~p"/images/brand-mark.svg"}
              width="56"
              height="56"
              alt=""
              class="df-brand-mark-img df-home-mark"
            />
            <h1 class="df-home-title text-4xl font-semibold tracking-tight text-base-content sm:text-5xl">
              DroneFeed
            </h1>
            <p class="df-home-copy max-w-xl text-lg text-base-content/70">
              Upload research flights with telemetry, publish pullable RTMP/RTSP feeds,
              and share a common library with your team.
            </p>
            <div class="flex flex-wrap gap-3 pt-2">
              <.link navigate={~p"/users/log-in"} class="btn btn-primary">
                Log in
              </.link>
              <.link navigate={~p"/users/request-access"} class="btn btn-ghost">
                Request an account
              </.link>
            </div>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    if socket.assigns.current_scope && socket.assigns.current_scope.user do
      {:ok, push_navigate(socket, to: ~p"/flights")}
    else
      {:ok, socket}
    end
  end
end
