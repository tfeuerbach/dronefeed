defmodule DroneFeed.Repo.Migrations.AddApiTokenExpiresAt do
  use Ecto.Migration

  def change do
    alter table(:api_tokens) do
      add :expires_at, :utc_datetime
    end

    create index(:api_tokens, [:expires_at])

    # Existing tokens get a 1-year window from now.
    execute(
      """
      UPDATE api_tokens
      SET expires_at = (inserted_at + INTERVAL '365 days')
      WHERE expires_at IS NULL
      """,
      ""
    )

    alter table(:api_tokens) do
      modify :expires_at, :utc_datetime, null: false
    end
  end
end
