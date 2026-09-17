defmodule DroneFeed.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        DroneFeedWeb.Telemetry,
        DroneFeed.Repo,
        {DNSCluster, query: Application.get_env(:drone_feed, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: DroneFeed.PubSub},
        {Registry, keys: :unique, name: DroneFeed.Streaming.PublisherRegistry},
        DroneFeed.Streaming.FlightLog,
        DroneFeed.Streaming.PublisherSupervisor,
        DroneFeed.Retention,
        DroneFeedWeb.Endpoint
      ] ++ boot_hooks()

    opts = [strategy: :one_for_one, name: DroneFeed.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp boot_hooks do
    if Application.get_env(:drone_feed, :restore_publishers_on_boot, true) do
      [
        {Task,
         fn ->
           # Allow Repo pool to come up
           Process.sleep(500)
           DroneFeed.Flights.restore_publishers()
         end}
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    DroneFeedWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
