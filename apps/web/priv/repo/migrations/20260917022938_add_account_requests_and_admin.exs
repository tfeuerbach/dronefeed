defmodule DroneFeed.Repo.Migrations.AddAccountRequestsAndAdmin do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :first_name, :string
      add :last_name, :string
      add :organization, :string
      add :location, :string
      add :role, :string, null: false, default: "user"
      add :status, :string, null: false, default: "active"
      add :approved_at, :utc_datetime
      add :approved_by_id, references(:users, type: :binary_id, on_delete: :nilify_all)
    end

    create index(:users, [:status])
    create index(:users, [:role])

    create table(:admin_notifications, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :string, null: false
      add :title, :string, null: false
      add :body, :text, null: false
      add :read_at, :utc_datetime
      add :subject_user_id, references(:users, type: :binary_id, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create index(:admin_notifications, [:read_at])
    create index(:admin_notifications, [:inserted_at])
  end
end
