defmodule Custode.Repo.Migrations.RetainReadCompositions do
  use Ecto.Migration
  def change do
    create table(:composition_records, primary_key: false) do
      add :id, :string, primary_key: true
      add :kind, :string, null: false
      add :name, :string, null: false
      add :data, :map, null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
    create index(:composition_records, [:kind, :inserted_at])
  end
end
