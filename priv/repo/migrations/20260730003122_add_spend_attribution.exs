defmodule Custode.Repo.Migrations.AddSpendAttribution do
  use Ecto.Migration

  def up do
    alter table(:spend) do
      add(:ingestion_key, :string)
      add(:attribution_key, :string)
      add(:attribution_status, :string, null: false, default: "legacy_unattributed")
      add(:role_binding_id, :string)
      add(:executor_kind, :string)
      add(:workflow_phase, :string)
    end

    execute("""
    UPDATE spend
    SET attribution_status =
      CASE
        WHEN attempt_id IS NULL THEN 'legacy_unattributed'
        WHEN EXISTS (
          SELECT 1 FROM attempts WHERE attempts.attempt_id = spend.attempt_id
        ) THEN 'legacy_attempt'
        ELSE 'unknown_attempt'
      END,
      attribution_key =
      CASE
        WHEN attempt_id IS NULL THEN 'legacy_agent:' || agent_id
        WHEN EXISTS (
          SELECT 1 FROM attempts WHERE attempts.attempt_id = spend.attempt_id
        ) THEN 'attempt:' || attempt_id
        ELSE 'unknown_attempt:' || attempt_id
      END,
      role_binding_id = (
        SELECT role_bindings.binding_id
        FROM attempts
        LEFT JOIN role_bindings ON role_bindings.id = attempts.role_binding_id
        WHERE attempts.attempt_id = spend.attempt_id
      ),
      executor_kind = (
        SELECT attempts.executor_kind
        FROM attempts
        WHERE attempts.attempt_id = spend.attempt_id
      ),
      workflow_phase = (
        SELECT json_extract(attempts.provenance, '$.active_phase')
        FROM attempts
        WHERE attempts.attempt_id = spend.attempt_id
      )
    """)

    create(
      unique_index(:spend, [:ingestion_key],
        where: "ingestion_key IS NOT NULL",
        name: :spend_ingestion_key_index
      )
    )

    create(index(:spend, [:attribution_key, :inserted_at]))
    create(index(:spend, [:attribution_status, :inserted_at]))
    create(index(:spend, [:role_binding_id, :inserted_at]))
    create(index(:spend, [:executor_kind, :inserted_at]))
    create(index(:spend, [:workflow_phase, :inserted_at]))
  end

  def down do
    drop(index(:spend, [:workflow_phase, :inserted_at]))
    drop(index(:spend, [:executor_kind, :inserted_at]))
    drop(index(:spend, [:role_binding_id, :inserted_at]))
    drop(index(:spend, [:attribution_status, :inserted_at]))
    drop(index(:spend, [:attribution_key, :inserted_at]))
    drop(index(:spend, [:ingestion_key], name: :spend_ingestion_key_index))

    alter table(:spend) do
      remove(:workflow_phase)
      remove(:executor_kind)
      remove(:role_binding_id)
      remove(:attribution_status)
      remove(:attribution_key)
      remove(:ingestion_key)
    end
  end
end
