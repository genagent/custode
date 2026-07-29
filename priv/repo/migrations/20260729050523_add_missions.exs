defmodule Custode.Repo.Migrations.AddMissions do
  use Ecto.Migration

  def change do
    create table(:missions) do
      add(:mission_id, :string, null: false)
      add(:key, :string, null: false)
      add(:purpose, :text, null: false)
      add(:lifecycle, :string, null: false)
      add(:status, :string, null: false, default: "active")
      add(:policy_ref, :string)
      add(:budget_ref, :string)
      add(:context_ref, :string)
      add(:retention_seconds, :integer, null: false, default: 0)
      add(:metadata, :map, null: false, default: %{})
      add(:archived_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:missions, [:mission_id]))
    create(unique_index(:missions, [:key]))
    create(index(:missions, [:status]))

    create table(:mission_targets) do
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:kind, :string, null: false)
      add(:external_id, :string, null: false)
      add(:display_name, :string, null: false)
      add(:metadata, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:mission_targets, [:mission_id, :kind, :external_id]))
    create(index(:mission_targets, [:kind, :external_id]))
  end
end
