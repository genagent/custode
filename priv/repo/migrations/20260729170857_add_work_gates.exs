defmodule Custode.Repo.Migrations.AddWorkGates do
  use Ecto.Migration

  def change do
    create table(:work_gates) do
      add(:gate_id, :string, null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:attempt_id, references(:attempts, on_delete: :restrict))

      add(
        :operation_call_id,
        references(:operation_calls,
          column: :call_id,
          type: :string,
          on_delete: :restrict
        )
      )

      add(:subject_kind, :string, null: false)
      add(:operation, :string, null: false)
      add(:arguments, :map, null: false)
      add(:preview, :map, null: false)
      add(:requester, :map, null: false)
      add(:resolver, :map)
      add(:status, :string, null: false, default: "open")
      add(:resolution, :map)
      add(:reason, :map)
      add(:work_item_version, :integer, null: false)
      add(:policy_version, :string, null: false)
      add(:grant_decision, :map, null: false)
      add(:external_preconditions, :map, null: false, default: %{})
      add(:definition_fingerprint, :string, null: false)
      add(:operation_idempotency_key, :string, null: false)
      add(:correlation_id, :string)
      add(:causation_id, :string)
      add(:resolved_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:work_gates, [:gate_id]))
    create(index(:work_gates, [:work_item_id, :status]))
    create(index(:work_gates, [:mission_id, :status]))
    create(index(:work_gates, [:attempt_id]))
    create(unique_index(:work_gates, [:operation_call_id]))
    create(index(:work_gates, [:correlation_id]))
    create(index(:work_gates, [:causation_id]))

    alter table(:work_events) do
      add(
        :gate_id,
        references(:work_gates,
          column: :gate_id,
          type: :string,
          on_delete: :restrict
        )
      )
    end

    drop(unique_index(:work_events, [:work_item_id, :work_item_version]))

    create(
      unique_index(:work_events, [:work_item_id, :work_item_version],
        name: :work_events_lifecycle_version_index,
        where: "kind IN ('work_item.created', 'work_item.transitioned', 'work_item.reopened')"
      )
    )

    create(unique_index(:work_events, [:gate_id], where: "gate_id IS NOT NULL"))
  end
end
