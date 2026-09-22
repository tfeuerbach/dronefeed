defmodule DroneFeed.Repo.Migrations.CreateApiTokens do
  use Ecto.Migration

  def change do
    create table(:api_tokens, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :prefix, :string, null: false
      add :token_hash, :binary, null: false
      add :last_used_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:api_tokens, [:user_id])
    create unique_index(:api_tokens, [:token_hash])
    create index(:api_tokens, [:prefix])
  end
end
