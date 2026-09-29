defmodule Custode.Repo.Migrations.CreateAgentAuthorizationSnapshots do
  use Ecto.Migration

  def change do
    create table(:agent_authorization_snapshots) do
      add(:routine_id, :string, null: false)
      add(:execution_revision, :string, null: false)
      add(:role, :string, null: false)
      add(:repo, :string)
      add(:workspace, :text, null: false)
      add(:working_dir, :text, null: false)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_authorization_snapshots, [:routine_id, :execution_revision]))
  end
end
