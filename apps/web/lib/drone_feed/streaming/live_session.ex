defmodule DroneFeed.Streaming.LiveSession do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "live_sessions" do
    field :name, :string
    field :stream_key, :string
    field :active, :boolean, default: true

    belongs_to :user, DroneFeed.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :stream_key, :active, :user_id])
    |> validate_required([:name, :stream_key, :user_id])
    |> unique_constraint(:stream_key)
  end
end
