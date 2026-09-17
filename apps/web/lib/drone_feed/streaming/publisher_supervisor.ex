defmodule DroneFeed.Streaming.PublisherSupervisor do
  @moduledoc false
  use DynamicSupervisor

  alias DroneFeed.Flights.Flight
  alias DroneFeed.Streaming.Publisher

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_publisher(%Flight{} = flight) do
    stop_publisher(flight.id)

    spec = %{
      id: {:publisher, flight.id},
      start: {Publisher, :start_link, [flight]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end

  def stop_publisher(flight_id) do
    Publisher.stop(flight_id)
  end
end
