defmodule DroneFeed.Retention do
  @moduledoc """
  Periodically deletes flights past the 5-day retention window.
  """

  use GenServer
  require Logger

  alias DroneFeed.Flights

  @interval_ms :timer.minutes(30)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    deleted = Flights.delete_expired_flights()

    if deleted > 0 do
      Logger.info("Retention sweep deleted #{deleted} expired flight(s)")
    end

    schedule()
    {:noreply, state}
  end

  defp schedule do
    Process.send_after(self(), :sweep, @interval_ms)
  end
end
