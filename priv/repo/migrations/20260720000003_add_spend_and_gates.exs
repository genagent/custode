defmodule Custode.Repo.Migrations.AddSpendAndGates do
  use Ecto.Migration

  def change do
    create table(:spend) do
      add :agent_id, :string, null: false
      add :cost_usd, :float, null: false
      add :outcome, :string, null: false, default: "turn"
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:spend, [:agent_id, :inserted_at])

    create table(:gates) do
      add :agent_id, :string, null: false
      add :kind, :string, null: false
      add :action_id, :string
      add :detail, :text
      add :status, :string, null: false, default: "open"
      timestamps(type: :utc_datetime_usec)
    end

    create index(:gates, [:agent_id, :status])
  end
end
