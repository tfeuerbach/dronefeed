defmodule DroneFeedWeb.PageController do
  use DroneFeedWeb, :controller

  def home(conn, _params) do
    if conn.assigns[:current_scope] do
      redirect(conn, to: ~p"/flights")
    else
      redirect(conn, to: ~p"/users/log-in")
    end
  end
end
