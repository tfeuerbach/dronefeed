defmodule DroneFeed.Flights.Slug do
  @moduledoc false

  import Ecto.Query

  alias DroneFeed.Flights.Flight
  alias DroneFeed.Repo

  @max_len 80

  @doc """
  Turns a flight name into a URL slug (`Cheyenne Feed 2` → `cheyenne-feed-2`).
  """
  def from_name(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "flight"
      slug -> String.slice(slug, 0, @max_len) |> String.trim_trailing("-")
    end
    |> case do
      "" -> "flight"
      slug -> slug
    end
  end

  def from_name(_), do: "flight"

  @doc """
  Returns a globally unique slug derived from `name`.
  Pass `:exclude_id` when updating an existing flight.
  """
  def unique(name, opts \\ []) do
    base = from_name(name)
    exclude_id = Keyword.get(opts, :exclude_id)
    taken = taken_slugs(base, exclude_id)

    if base not in taken do
      base
    else
      Enum.find_value(2..10_000, fn n ->
        candidate = "#{String.slice(base, 0, @max_len - 6)}-#{n}"

        if candidate not in taken, do: candidate
      end) || "#{base}-#{System.unique_integer([:positive])}"
    end
  end

  defp taken_slugs(base, exclude_id) do
    prefix = "#{base}%"

    query =
      Flight
      |> where([f], f.slug == ^base or like(f.slug, ^prefix))
      |> select([f], f.slug)

    query =
      if exclude_id do
        where(query, [f], f.id != ^exclude_id)
      else
        query
      end

    MapSet.new(Repo.all(query))
  end
end
