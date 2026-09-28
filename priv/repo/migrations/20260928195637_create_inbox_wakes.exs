defmodule Custode.Repo.Migrations.CreateInboxWakes do
  use Ecto.Migration

  def change do
    create table(:inbox_wakes, primary_key: false) do
      add(:routine_id, :string, primary_key: true)
      add(:wake_id, :string, null: false)
      add(:state, :string, null: false, default: "pending")
      add(:reason, :string, null: false, default: "inbox_activity")
      add(:note_count, :integer, null: false, default: 1)
      add(:first_note_at, :utc_datetime_usec, null: false)
      add(:last_note_at, :utc_datetime_usec, null: false)
      add(:due_at, :utc_datetime_usec, null: false)
      add(:blocked_by, :string)
      add(:spend_override, :boolean, null: false, default: false)
      add(:retry_count, :integer, null: false, default: 0)
      add(:claim_token, :string)
      add(:claimed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:inbox_wakes, [:wake_id]))
    create(index(:inbox_wakes, [:state, :due_at]))
  end
end
