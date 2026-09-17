defmodule DroneFeed.Repo do
  use Ecto.Repo,
    otp_app: :drone_feed,
    adapter: Ecto.Adapters.Postgres
end
