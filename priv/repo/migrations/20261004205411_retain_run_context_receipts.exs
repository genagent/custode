defmodule Custode.Repo.Migrations.RetainRunContextReceipts do
  use Ecto.Migration

  def change do
    create table(:run_context_receipts, primary_key: false) do
      add(:receipt_id, :text, primary_key: true)
      add(:agent_id, :text, null: false)
      add(:record, :map, null: false)
      add(:payload, :text)
      add(:at, :utc_datetime_usec, null: false)
    end

    create(index(:run_context_receipts, [:agent_id, :at]))
  end
end
