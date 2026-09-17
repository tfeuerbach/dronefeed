defmodule DroneFeed.Repo.Migrations.CreateFlights do
  use Ecto.Migration

  def change do
    create table(:flights, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :video_path, :string, null: false
      add :srt_path, :string
      add :klv_path, :string
      add :original_video_name, :string
      add :stream_key, :string, null: false
      add :publishing, :boolean, null: false, default: false
      add :expires_at, :utc_datetime, null: false
      add :user_id, references(:users, on_delete: :delete_all, type: :binary_id), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:flights, [:user_id])
    create unique_index(:flights, [:stream_key])
    create index(:flights, [:expires_at])
    create index(:flights, [:publishing])
  end
end
