defmodule DroneFeed.Accounts.AdminNotification do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "admin_notifications" do
    field :kind, :string
    field :title, :string
    field :body, :string
    field :read_at, :utc_datetime

    belongs_to :subject_user, DroneFeed.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:kind, :title, :body, :subject_user_id, :read_at])
    |> validate_required([:kind, :title, :body])
  end
end
