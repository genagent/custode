defmodule Custode.Repo.Migrations.AddLegacyRoutineMissionMappings do
  use Ecto.Migration

  def change do
    create table(:legacy_routine_mission_mappings) do
      add(:mapping_id, :string, null: false)
      add(:legacy_routine_id, :string, null: false)
      add(:mission_id, references(:missions, on_delete: :restrict))
      add(:strategy, :string, null: false)
      add(:mapping_identity, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:source_snapshot, :map, null: false)
      add(:last_observed_snapshot, :map, null: false)
      add(:last_observed_fingerprint, :string, null: false)
      add(:exception, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:legacy_routine_mission_mappings, [:mapping_id]))
    create(unique_index(:legacy_routine_mission_mappings, [:legacy_routine_id]))
    create(index(:legacy_routine_mission_mappings, [:mission_id]))
    create(index(:legacy_routine_mission_mappings, [:status]))
  end
end
