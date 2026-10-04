defmodule Custode.Repo.Migrations.AddFeedIngestionKey do
  use Ecto.Migration

  def change do
    alter table(:feed_entries) do
      add :ingestion_key, :string
    end

    create unique_index(:feed_entries, [:ingestion_key])
  end
end
