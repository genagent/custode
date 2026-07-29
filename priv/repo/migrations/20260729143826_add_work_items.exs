defmodule Custode.Repo.Migrations.AddWorkItems do
  use Ecto.Migration

  def change do
    create table(:work_items) do
      add(:work_item_id, :string, null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:parent_id, references(:work_items, on_delete: :restrict))
      add(:kind, :string, null: false)
      add(:workflow_version, :integer, null: false)
      add(:objective, :text, null: false)
      add(:acceptance_criteria, :map, null: false)
      add(:state, :string, null: false, default: "proposed")
      add(:phase, :string, null: false)
      add(:priority, :integer, null: false, default: 0)
      add(:policy_ref, :string)
      add(:source, :string, null: false)
      add(:external_key, :string, null: false)
      add(:version, :integer, null: false, default: 1)
      add(:active_attempt_id, :string)
      add(:active_operation_call_id, :string)
      add(:waiting_condition, :map)
      add(:blocked_reason, :map)
      add(:outcome, :map)
      add(:completed_at, :utc_datetime_usec)
      add(:cancelled_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:work_items, [:work_item_id]))
    create(unique_index(:work_items, [:source, :external_key]))
    create(index(:work_items, [:mission_id, :state]))
    create(index(:work_items, [:parent_id]))
    create(index(:work_items, [:kind, :workflow_version, :phase]))
    create(index(:work_items, [:active_attempt_id]))
    create(index(:work_items, [:active_operation_call_id]))

    create table(:work_events) do
      add(:event_id, :string, null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:kind, :string, null: false)
      add(:actor, :map, null: false)
      add(:operation, :string, null: false)
      add(:operation_call_id, :string)
      add(:before_state, :string)
      add(:before_phase, :string)
      add(:after_state, :string, null: false)
      add(:after_phase, :string, null: false)
      add(:before_version, :integer)
      add(:work_item_version, :integer, null: false)
      add(:evidence, :map, null: false, default: %{})
      add(:correlation_id, :string)
      add(:causation_id, :string)
      timestamps(updated_at: false, type: :utc_datetime_usec)
    end

    create(unique_index(:work_events, [:event_id]))
    create(unique_index(:work_events, [:operation_call_id]))
    create(unique_index(:work_events, [:work_item_id, :work_item_version]))
    create(index(:work_events, [:mission_id, :inserted_at]))
    create(index(:work_events, [:correlation_id]))
    create(index(:work_events, [:causation_id]))
  end
end
