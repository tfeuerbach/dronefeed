defmodule DroneFeed.Streaming.LiveSession do
  use Ecto.Schema
  import Ecto.Changeset

  @ingest_modes ~w(push udp_mpegts)

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "live_sessions" do
    field :name, :string
    field :stream_key, :string
    field :active, :boolean, default: true
    field :publishing, :boolean, default: false
    field :ingest_mode, :string, default: "push"
    field :udp_port, :integer

    belongs_to :user, DroneFeed.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def ingest_modes, do: @ingest_modes

  def changeset(session, attrs) do
    session
    |> cast(attrs, [:name, :stream_key, :active, :publishing, :user_id, :ingest_mode, :udp_port])
    |> validate_required([:name, :stream_key, :user_id, :ingest_mode])
    |> validate_inclusion(:ingest_mode, @ingest_modes)
    |> validate_udp_port()
    |> unique_constraint(:stream_key)
    |> unique_constraint(:udp_port, name: :live_sessions_active_udp_port_index)
  end

  def publish_changeset(session, publishing) when is_boolean(publishing) do
    change(session, publishing: publishing)
  end

  defp validate_udp_port(changeset) do
    mode = get_field(changeset, :ingest_mode)
    active = get_field(changeset, :active)

    cond do
      mode == "udp_mpegts" and active != false ->
        changeset
        |> validate_required([:udp_port])
        |> validate_number(:udp_port, greater_than: 0, less_than: 65_536)

      mode != "udp_mpegts" ->
        put_change(changeset, :udp_port, nil)

      true ->
        changeset
    end
  end
end
