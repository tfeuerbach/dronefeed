defmodule DroneFeed.Repo.Migrations.CreateLiveSessions do
  use Ecto.Migration

  def change do
    create table(:live_sessions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :stream_key, :string, null: false
      add :active, :boolean, null: false, default: true
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:live_sessions, [:user_id])
    create unique_index(:live_sessions, [:stream_key])
    create index(:live_sessions, [:active])
  end
end
