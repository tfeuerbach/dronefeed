defmodule DroneFeed.Flights.Flight do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "flights" do
    field :name, :string
    field :video_path, :string
    field :srt_path, :string
    field :klv_path, :string
    field :original_video_name, :string
    field :stream_key, :string
    field :publishing, :boolean, default: false
    field :expires_at, :utc_datetime

    belongs_to :user, DroneFeed.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(flight, attrs) do
    flight
    |> cast(attrs, [
      :name,
      :video_path,
      :srt_path,
      :klv_path,
      :original_video_name,
      :stream_key,
      :publishing,
      :expires_at,
      :user_id
    ])
    |> validate_required([:name, :video_path, :stream_key, :expires_at, :user_id])
    |> unique_constraint(:stream_key)
  end

  def publish_changeset(flight, publishing) when is_boolean(publishing) do
    change(flight, publishing: publishing)
  end
end
