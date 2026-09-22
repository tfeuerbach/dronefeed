defmodule DroneFeed.Repo.Migrations.AddFlightSlug do
  use Ecto.Migration

  def up do
    alter table(:flights) do
      add :slug, :string
    end

    flush()

    # Temporary unique placeholder from id; app will rewrite to name-based slugs next.
    execute("""
    UPDATE flights
    SET slug = REPLACE(id::text, '-', '')
    WHERE slug IS NULL
    """)

    alter table(:flights) do
      modify :slug, :string, null: false
    end

    create unique_index(:flights, [:slug])
  end

  def down do
    drop_if_exists index(:flights, [:slug])

    alter table(:flights) do
      remove :slug
    end
  end
end
