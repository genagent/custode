defmodule Custode.Repo.Migrations.AddNotebook do
  use Ecto.Migration

  def change do
    create table(:journal_entries) do
      add :routine_id, :string, null: false
      add :title, :string
      add :body, :text, null: false
      add :source, :string, null: false, default: "sweep"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_entries, [:routine_id, :inserted_at])

    create table(:todos) do
      add :routine_id, :string, null: false
      add :text, :string, null: false
      add :status, :string, null: false, default: "open"
      add :source, :string, null: false, default: "sweep"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:todos, [:routine_id, :status])

    create table(:memories) do
      add :agent_id, :string, null: false
      add :key, :string, null: false
      add :value, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:memories, [:agent_id, :key])
  end
end
