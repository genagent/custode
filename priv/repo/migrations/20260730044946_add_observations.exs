defmodule Custode.Repo.Migrations.AddObservations do
  use Ecto.Migration

  # Typed sensor output aggregated by deduplication key (#246). One row per
  # distinct observed condition, not one row per sighting: repeated evidence
  # increments the aggregate rather than accumulating duplicates, which is
  # what makes "seen this three times" a threshold rather than a count of
  # rows nobody deduplicated.
  def change do
    create table(:observations) do
      add(:observation_id, :string, null: false)
      add(:dedup_key, :string, null: false)
      add(:source, :string, null: false)
      add(:target, :string, null: false)
      add(:revision, :string)
      add(:evidence, :map, null: false, default: %{})
      add(:occurrences, :integer, null: false, default: 1)
      add(:first_observed_at, :utc_datetime_usec, null: false)
      add(:last_observed_at, :utc_datetime_usec, null: false)
      add(:mission_id, references(:missions, on_delete: :nilify_all))
      add(:disposition, :string, null: false, default: "watching")
      add(:disposition_reason, :map, null: false, default: %{})
      add(:threshold_version, :string)
      add(:policy_version, :string)
      add(:control_work_item_id, :string)
      add(:gate_id, :string)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:observations, [:dedup_key]))
    create(unique_index(:observations, [:observation_id]))
    create(index(:observations, [:disposition]))
    create(index(:observations, [:mission_id]))
  end
end
