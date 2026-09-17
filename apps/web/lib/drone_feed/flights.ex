defmodule DroneFeed.Flights do
  @moduledoc """
  Recorded flight uploads, retention, and publish toggles.

  Authenticated users can browse every non-expired flight. Mutating publish /
  delete stays with the uploader.
  """

  import Ecto.Query

  alias DroneFeed.Accounts.Scope
  alias DroneFeed.Flights.Flight
  alias DroneFeed.Repo
  alias DroneFeed.Streaming.PublisherSupervisor

  @doc """
  Lists all non-expired flights (shared library).
  """
  def list_flights(%Scope{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Flight
    |> where([f], f.expires_at > ^now)
    |> order_by([f], desc: f.inserted_at)
    |> preload(:user)
    |> Repo.all()
  end

  @doc """
  Flights currently publishing to MediaMTX for external RTMP/RTSP pull.
  """
  def list_published_flights(%Scope{}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Flight
    |> where([f], f.publishing == true and f.expires_at > ^now)
    |> order_by([f], desc: f.updated_at)
    |> preload(:user)
    |> Repo.all()
  end

  def get_flight!(%Scope{}, id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Flight
    |> where([f], f.id == ^id and f.expires_at > ^now)
    |> preload(:user)
    |> Repo.one!()
  end

  def get_flight(id) when is_binary(id), do: Repo.get(Flight, id)

  def owns?(%Scope{user: %{id: user_id}}, %Flight{user_id: user_id}), do: true
  def owns?(_, _), do: false

  def create_flight(%Scope{user: user}, attrs, files) do
    retention_days = Application.fetch_env!(:drone_feed, :retention_days)

    expires_at =
      DateTime.utc_now()
      |> DateTime.add(retention_days * 24 * 3600, :second)
      |> DateTime.truncate(:second)

    stream_key = generate_stream_key()
    id = Ecto.UUID.generate()

    with {:ok, paths} <- persist_files(user.id, id, files) do
      %Flight{id: id}
      |> Flight.changeset(
        Map.merge(attrs, %{
          "user_id" => user.id,
          "stream_key" => stream_key,
          "expires_at" => expires_at,
          "video_path" => paths.video_path,
          "srt_path" => paths.srt_path,
          "klv_path" => paths.klv_path,
          "original_video_name" => paths.original_video_name
        })
      )
      |> Repo.insert()
    end
  end

  def change_flight(%Flight{} = flight, attrs \\ %{}) do
    Flight.changeset(flight, attrs)
  end

  def set_publishing(%Scope{} = scope, flight_id, publishing) when is_boolean(publishing) do
    flight = get_flight!(scope, flight_id)

    if owns?(scope, flight) do
      case flight |> Flight.publish_changeset(publishing) |> Repo.update() do
        {:ok, flight} ->
          if publishing do
            DroneFeed.Streaming.FlightLog.clear(flight.id)
            DroneFeed.Streaming.FlightLog.info(flight.id, :system, "Public feed enabled by user")

            case PublisherSupervisor.start_publisher(flight) do
              {:ok, _pid} ->
                {:ok, Repo.preload(flight, :user)}

              {:error, reason} ->
                DroneFeed.Streaming.FlightLog.error(
                  flight.id,
                  :system,
                  "Failed to start publisher: #{inspect(reason)}"
                )

                _ = flight |> Flight.publish_changeset(false) |> Repo.update()
                {:error, reason}
            end
          else
            DroneFeed.Streaming.FlightLog.info(flight.id, :system, "Public feed disabled by user")
            PublisherSupervisor.stop_publisher(flight.id)
            {:ok, Repo.preload(flight, :user)}
          end

        error ->
          error
      end
    else
      {:error, :forbidden}
    end
  end

  def delete_flight(%Scope{} = scope, flight_id) do
    flight = get_flight!(scope, flight_id)

    if owns?(scope, flight) do
      PublisherSupervisor.stop_publisher(flight.id)
      cleanup_files(flight)
      Repo.delete(flight)
    else
      {:error, :forbidden}
    end
  end

  def delete_expired_flights do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    expired =
      Flight
      |> where([f], f.expires_at <= ^now)
      |> Repo.all()

    Enum.each(expired, fn flight ->
      PublisherSupervisor.stop_publisher(flight.id)
      cleanup_files(flight)
      Repo.delete(flight)
    end)

    length(expired)
  end

  def restore_publishers do
    Flight
    |> where([f], f.publishing == true)
    |> Repo.all()
    |> Enum.each(&PublisherSupervisor.start_publisher/1)
  end

  defp persist_files(user_id, flight_id, %{video: video} = files) do
    dir = Path.join([storage_root(), "flights", user_id, flight_id])
    video_dest = Path.join(dir, "video" <> Path.extname(video.filename))

    with :ok <- mkdir_p(dir),
         :ok <- cp(video.path, video_dest),
         {:ok, srt_path} <- copy_optional(Map.get(files, :srt), Path.join(dir, "metadata.srt")),
         {:ok, klv_path} <-
           copy_optional(
             Map.get(files, :klv),
             &Path.join(dir, "metadata" <> Path.extname(&1))
           ) do
      {:ok,
       %{
         video_path: video_dest,
         srt_path: srt_path,
         klv_path: klv_path,
         original_video_name: video.filename
       }}
    end
  end

  defp persist_files(_user_id, _flight_id, _files), do: {:error, :video_required}

  defp mkdir_p(dir) do
    case File.mkdir_p(dir) do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp cp(from, to) do
    case File.cp(from, to) do
      :ok -> :ok
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp copy_optional(nil, _dest), do: {:ok, nil}

  defp copy_optional(%{path: path, filename: filename}, dest_fun) when is_function(dest_fun, 1) do
    dest = dest_fun.(filename)

    case File.cp(path, dest) do
      :ok -> {:ok, dest}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp copy_optional(%{path: path}, dest) when is_binary(dest) do
    case File.cp(path, dest) do
      :ok -> {:ok, dest}
      {:error, reason} -> {:error, {:storage, reason}}
    end
  end

  defp cleanup_files(%Flight{video_path: path}) when is_binary(path) do
    dir = Path.dirname(path)
    File.rm_rf(dir)
  end

  defp cleanup_files(_), do: :ok

  defp storage_root, do: Application.fetch_env!(:drone_feed, :storage_root)

  defp generate_stream_key do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
