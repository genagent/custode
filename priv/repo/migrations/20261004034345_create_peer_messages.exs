defmodule Custode.Repo.Migrations.CreatePeerMessages do
  use Ecto.Migration

  def change do
    create table(:peer_messages, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:sender, :string, null: false)
      add(:recipient, :string, null: false)
      add(:kind, :string, null: false)
      add(:subject, :string, null: false)
      add(:body, :text, null: false)
      add(:idempotency_key, :string, null: false)
      add(:reply_to, :uuid)
      add(:correlation_id, :uuid, null: false)
      add(:depth, :integer, null: false, default: 0)
      add(:delivery_state, :string, null: false, default: "pending")
      add(:error, :text)
      add(:delivered_at, :utc_datetime_usec)
      add(:acknowledged_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:peer_messages, [:sender, :idempotency_key]))
    create(index(:peer_messages, [:sender, :inserted_at]))
    create(index(:peer_messages, [:recipient, :inserted_at]))
    create(index(:peer_messages, [:correlation_id, :inserted_at]))
    create(index(:peer_messages, [:delivery_state]))
  end
end
