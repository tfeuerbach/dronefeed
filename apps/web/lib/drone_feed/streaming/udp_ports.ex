defmodule DroneFeed.Streaming.UdpPorts do
  @moduledoc """
  Allocates UDP ports for live MPEG-TS ingest and VOD publish into MediaMTX.

  In-process reservations (Agent) plus active `live_sessions.udp_port` rows.
  """

  use Agent
  import Ecto.Query

  alias DroneFeed.Repo
  alias DroneFeed.Streaming.LiveSession

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> MapSet.new() end, name: __MODULE__)
  end

  @doc """
  Reserves the next free port in the configured range.
  Caller must `release/1` when finished (or on failure).
  """
  def allocate do
    min = Application.fetch_env!(:drone_feed, :udp_ingest_port_min)
    max = Application.fetch_env!(:drone_feed, :udp_ingest_port_max)
    db_used = db_ports()

    Agent.get_and_update(__MODULE__, fn reserved ->
      used = MapSet.union(reserved, db_used)

      case Enum.find(min..max, &(not MapSet.member?(used, &1))) do
        nil ->
          {{:error, :udp_ports_exhausted}, reserved}

        port ->
          {{:ok, port}, MapSet.put(reserved, port)}
      end
    end)
  end

  def release(nil), do: :ok

  def release(port) when is_integer(port) do
    Agent.update(__MODULE__, &MapSet.delete(&1, port))
  end

  defp db_ports do
    LiveSession
    |> where([s], s.active == true and not is_nil(s.udp_port))
    |> select([s], s.udp_port)
    |> Repo.all()
    |> MapSet.new()
  end
end
