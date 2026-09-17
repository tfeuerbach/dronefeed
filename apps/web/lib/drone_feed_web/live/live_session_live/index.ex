defmodule DroneFeedWeb.LiveSessionLive.Index do
  use DroneFeedWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, push_navigate(socket, to: ~p"/flights")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div></div>
    """
  end
end
