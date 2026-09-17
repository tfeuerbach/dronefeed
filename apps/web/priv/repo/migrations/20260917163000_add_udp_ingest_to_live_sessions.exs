defmodule DroneFeed.Repo.Migrations.AddUdpIngestToLiveSessions do
  use Ecto.Migration

  def change do
    alter table(:live_sessions) do
      add :ingest_mode, :string, null: false, default: "push"
      add :udp_port, :integer
    end

    create index(:live_sessions, [:ingest_mode])

    create unique_index(:live_sessions, [:udp_port],
      where: "active = true AND udp_port IS NOT NULL",
      name: :live_sessions_active_udp_port_index
    )
  end
end
