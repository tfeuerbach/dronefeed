defmodule DroneFeed.Repo.Migrations.AddPublishingToLiveSessions do
  use Ecto.Migration

  def change do
    alter table(:live_sessions) do
      add :publishing, :boolean, null: false, default: false
    end

    create index(:live_sessions, [:publishing])
  end
end
