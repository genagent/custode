defmodule Custode.Repo.Migrations.CreateAgentHandoffIntents do
  use Ecto.Migration

  def change do
    create table(:agent_handoff_intents, primary_key: false) do
      add(:agent_id, :string, primary_key: true)
      add(:pause_context, :map, null: false)
      timestamps(type: :utc_datetime_usec)
    end
  end
end
