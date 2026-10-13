defmodule AdapterProof.Repo.Migrations.CreateProofJournal do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :paused, :boolean, null: false, default: false
      add :revision, :integer, null: false, default: 0
      add :generation, :integer, null: false, default: 0
      add :active_turn_id, :integer
    end

    create table(:project_turns) do
      add :project_id, references(:projects), null: false
      add :state, :string, null: false
      add :spec, :map, null: false
      add :report, :map
    end

    create table(:project_turn_attempts) do
      add :turn_id, references(:project_turns), null: false
      add :generation, :integer, null: false
      add :phase, :string, null: false
      add :spec, :map, null: false
      add :spec_hash, :string, null: false
      add :native, :map
      add :native_inventory, :map, null: false, default: %{}
      add :terminal, :map
      add :quiescence, :map
      add :stop_requested, :boolean, null: false, default: false
    end

    create unique_index(:project_turn_attempts, [:turn_id])
    create unique_index(:projects, [:active_turn_id])
    Oban.Migrations.SQLite.up([])
  end
end
