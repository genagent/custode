defmodule Custode.Repo.Migrations.AddSubAgents do
  use Ecto.Migration

  # Sub-agent revival (#5): routines self-heal because the crontab is their
  # spec; sub-agents had no spec anywhere and died silently with the
  # instance. This row IS the spec: enough to offer the parent a revival
  # handle (args + resume session) after a restart. Offer, never auto-revive.
  def change do
    create table(:sub_agents, primary_key: false) do
      add(:agent_id, :string, primary_key: true)
      add(:parent, :string, null: false)
      add(:workspace, :string, null: false)
      add(:system_prompt, :text)
      add(:model, :string)
      add(:session_id, :string)
      add(:spawned_at, :utc_datetime_usec, null: false)
      add(:last_turn_at, :utc_datetime_usec)
    end

    create(index(:sub_agents, [:parent]))
  end
end
