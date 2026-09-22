defmodule DroneFeed.Accounts.ApiToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "api_tokens" do
    field :name, :string
    field :prefix, :string
    field :token_hash, :binary, redact: true
    field :last_used_at, :utc_datetime
    # Only set when creating — never persisted.
    field :plaintext, :string, virtual: true, redact: true

    belongs_to :user, DroneFeed.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [:name])
    |> update_change(:name, &name_trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 80)
  end

  defp name_trim(nil), do: nil
  defp name_trim(name) when is_binary(name), do: String.trim(name)
end
