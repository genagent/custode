defmodule Custode.Repo.Migrations.AddAgentPanels do
  use Ecto.Migration

  # Agent-authored panels, gated (#100 v1): an append-only log of an agent's
  # panel versions. Each version is HTML the agent proposed; the operator
  # approves or rejects it, and only an approved version renders (inside a
  # locked-down iframe -- the BEAM never executes it). Append-only so
  # provenance survives and a prior approved version can be restored.
  def change do
    create table(:agent_panels) do
      add(:routine_id, :string, null: false)
      add(:html, :text, null: false)
      # "pending" | "approved" | "rejected"
      add(:status, :string, null: false, default: "pending")
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:agent_panels, [:routine_id, :status]))
  end
end
