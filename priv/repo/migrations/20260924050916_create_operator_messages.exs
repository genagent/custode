defmodule Custode.Repo.Migrations.CreateOperatorMessages do
  use Ecto.Migration

  def change do
    create table(:operator_messages) do
      add(:message_id, :string, null: false)
      add(:caller_kind, :string, null: false)
      add(:caller_id, :string, null: false)
      add(:transport, :string, null: false)
      add(:target_agent_id, :string, null: false)
      add(:idempotency_key, :string, null: false)
      add(:prompt_hash, :string, null: false)
      add(:prompt, :text, null: false)
      add(:provider_correlation_id, :string, null: false)
      add(:continues_message_id, :string)
      add(:status, :string, null: false, default: "queued")
      add(:delivery, :string)
      add(:provider, :string)
      add(:agent_generation, :string)
      add(:agent_turn_id, :string)
      add(:arc_id, :string)
      add(:provider_session_id, :string)
      add(:detail, :text)
      add(:result, :map)
      add(:error, :map)
      add(:started_at, :utc_datetime_usec)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:operator_messages, [:message_id]))

    create(
      unique_index(
        :operator_messages,
        [:caller_kind, :caller_id, :target_agent_id, :idempotency_key],
        name: :operator_messages_idempotency_index
      )
    )

    create(index(:operator_messages, [:provider_correlation_id, :status]))
    create(index(:operator_messages, [:target_agent_id, :status]))
    create(index(:operator_messages, [:continues_message_id]))
  end
end
