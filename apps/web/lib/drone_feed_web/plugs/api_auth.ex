defmodule DroneFeedWeb.Plugs.ApiAuth do
  @moduledoc """
  Authenticates API requests via `Authorization: Bearer <token>` or `X-Api-Key`.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias DroneFeed.Accounts
  alias DroneFeed.Accounts.Scope

  def init(opts), do: opts

  def call(conn, _opts) do
    case extract_token(conn) do
      nil ->
        unauthorized(conn)

      token ->
        case Accounts.get_user_by_api_token(token) do
          nil ->
            unauthorized(conn)

          user ->
            assign(conn, :current_scope, Scope.for_user(user))
        end
    end
  end

  defp extract_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        String.trim(token)

      ["bearer " <> token] ->
        String.trim(token)

      _ ->
        case get_req_header(conn, "x-api-key") do
          [token | _] -> String.trim(token)
          _ -> nil
        end
    end
  end

  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized", message: "Valid API token required (Authorization: Bearer … or X-Api-Key)"})
    |> halt()
  end
end
