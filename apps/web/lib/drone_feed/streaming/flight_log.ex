defmodule DroneFeed.Streaming.FlightLog do
  @moduledoc """
  Ring-buffer event log per flight for publish/debug (FFmpeg, mux, MediaMTX auth).

  Entries are kept in ETS and broadcast on PubSub so LiveViews can render a
  live terminal without polling.
  """

  use GenServer

  @table :drone_feed_flight_logs
  @max_entries 400
  @pubsub DroneFeed.PubSub

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def topic(flight_id), do: "flight_log:#{flight_id}"

  def subscribe(flight_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(flight_id))
  end

  def list(flight_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, @max_entries)
    min_level = Keyword.get(opts, :min_level, :debug)

    flight_id
    |> do_list()
    |> Enum.filter(&(level_rank(&1.level) >= level_rank(min_level)))
    |> Enum.take(-limit)
  end

  def clear(flight_id) do
    GenServer.call(__MODULE__, {:clear, flight_id})
  end

  def append(flight_id, level, source, message, meta \\ %{})
      when level in [:debug, :info, :warn, :error] and is_binary(message) do
    entry = %{
      id: System.unique_integer([:positive]),
      at: DateTime.utc_now(:microsecond),
      level: level,
      source: to_string(source),
      message: String.trim(message) |> String.slice(0, 2000),
      meta: stringify_meta(meta)
    }

    GenServer.call(__MODULE__, {:append, flight_id, entry})
    entry
  end

  def info(flight_id, source, message, meta \\ %{}),
    do: append(flight_id, :info, source, message, meta)

  def warn(flight_id, source, message, meta \\ %{}),
    do: append(flight_id, :warn, source, message, meta)

  def error(flight_id, source, message, meta \\ %{}),
    do: append(flight_id, :error, source, message, meta)

  def debug(flight_id, source, message, meta \\ %{}),
    do: append(flight_id, :debug, source, message, meta)

  @impl true
  def init(_opts) do
    table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:append, flight_id, entry}, _from, state) do
    entries = do_list(flight_id) ++ [entry]
    trimmed = Enum.take(entries, -@max_entries)
    :ets.insert(@table, {flight_id, trimmed})
    Phoenix.PubSub.broadcast(@pubsub, topic(flight_id), {:flight_log, entry})
    {:reply, :ok, state}
  end

  def handle_call({:clear, flight_id}, _from, state) do
    :ets.delete(@table, flight_id)
    Phoenix.PubSub.broadcast(@pubsub, topic(flight_id), {:flight_log_cleared, flight_id})
    {:reply, :ok, state}
  end

  defp do_list(flight_id) do
    case :ets.lookup(@table, flight_id) do
      [{^flight_id, entries}] when is_list(entries) -> entries
      _ -> []
    end
  end

  defp level_rank(:debug), do: 10
  defp level_rank(:info), do: 20
  defp level_rank(:warn), do: 30
  defp level_rank(:error), do: 40
  defp level_rank(_), do: 0

  defp stringify_meta(meta) when is_map(meta) do
    Map.new(meta, fn {k, v} -> {to_string(k), stringify_value(v)} end)
  end

  defp stringify_value(v) when is_binary(v), do: v
  defp stringify_value(v) when is_atom(v), do: Atom.to_string(v)
  defp stringify_value(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp stringify_value(v), do: inspect(v)
end
