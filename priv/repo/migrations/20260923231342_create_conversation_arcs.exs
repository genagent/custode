defmodule Custode.Repo.Migrations.CreateConversationArcs do
  use Ecto.Migration

  def change do
    create table(:conversation_arcs) do
      add(:routine_id, :string, null: false)
      add(:arc_id, :string, null: false)
      add(:logical_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:provider, :string, null: false)
      add(:provider_session_id, :string)
      add(:host_id, :string, null: false)
      add(:workspace_identity, :text, null: false)
      add(:configuration_fingerprint, :string, null: false)
      add(:parent_id, references(:conversation_arcs, on_delete: :nilify_all))
      add(:state, :string, null: false, default: "active")
      add(:last_decision, :string, null: false)
      add(:last_reason, :string, null: false)
      add(:last_outcome, :string)
      add(:rotation_reason, :string)
      add(:opened_at, :utc_datetime_usec, null: false)
      add(:last_used_at, :utc_datetime_usec, null: false)
      add(:closed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:conversation_arcs, [:routine_id, :logical_id],
        name: :conversation_arcs_active_identity_index,
        where: "state = 'active'"
      )
    )

    create(unique_index(:conversation_arcs, [:routine_id, :arc_id]))
    create(index(:conversation_arcs, [:routine_id, :state]))
    create(index(:conversation_arcs, [:provider_session_id]))
    create(index(:conversation_arcs, [:parent_id]))

    create table(:conversation_arc_events) do
      add(:conversation_arc_id, references(:conversation_arcs, on_delete: :delete_all),
        null: false
      )

      add(:kind, :string, null: false)
      add(:decision, :string)
      add(:reason, :string)
      add(:outcome, :string)
      add(:provider_session_id, :string)
      add(:details, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(index(:conversation_arc_events, [:conversation_arc_id, :inserted_at]))
  end
end
