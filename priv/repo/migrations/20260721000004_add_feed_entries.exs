defmodule Custode.Repo.Migrations.AddFeedEntries do
  use Ecto.Migration

  def change do
    create table(:feed_entries) do
      add :agent, :string
      add :event, :string, null: false
      # the full entry as JSON (string keys), exactly what tail/1 returns
      add :entry, :text, null: false
      add :at, :utc_datetime_usec, null: false
    end

    create index(:feed_entries, [:agent, :id])
  end
end
