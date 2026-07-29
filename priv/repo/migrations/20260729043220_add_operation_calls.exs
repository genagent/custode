defmodule Custode.Repo.Migrations.AddOperationCalls do
  use Ecto.Migration

  def change do
    create table(:operation_calls) do
      add(:call_id, :string, null: false)
      add(:operation, :string, null: false)
      add(:arguments, :map, null: false)
      add(:actor, :map, null: false)
      add(:transport, :string, null: false)
      add(:authorization_result, :map)
      add(:grant, :string)
      add(:risk, :string, null: false)
      add(:idempotency_scope, :string, null: false)
      add(:idempotency_key, :string, null: false)
      add(:expected_versions, :map)
      add(:preconditions, :map)
      add(:correlation_id, :string)
      add(:causation_id, :string)
      add(:mission_id, :string)
      add(:work_item_id, :string)
      add(:attempt_id, :string)
      add(:dry_run, :boolean, null: false, default: false)
      add(:effect_preview, :map)
      add(:result, :map)
      add(:effects, :map)
      add(:error, :map)
      add(:status, :string, null: false)
      add(:lease_token, :string)
      add(:lease_expires_at, :utc_datetime_usec)
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:operation_calls, [:call_id]))

    create(
      unique_index(
        :operation_calls,
        [:operation, :idempotency_scope, :idempotency_key]
      )
    )

    create(index(:operation_calls, [:status]))
    create(index(:operation_calls, [:correlation_id]))
    create(index(:operation_calls, [:causation_id]))
  end
end
