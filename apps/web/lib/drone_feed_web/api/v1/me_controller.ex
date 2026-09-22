defmodule DroneFeedWeb.Api.V1.MeController do
  use DroneFeedWeb, :controller

  alias DroneFeedWeb.Api.V1.JSON

  def show(conn, _params) do
    user = conn.assigns.current_scope.user
    json(conn, %{data: JSON.user(user)})
  end
end
