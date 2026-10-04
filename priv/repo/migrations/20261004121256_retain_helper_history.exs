defmodule Custode.Repo.Migrations.RetainHelperHistory do
  use Ecto.Migration

  def change do
    create table(:helper_records) do
      add :agent_id, :string, null: false
      add :parent, :string, null: false
      add :spawned_at, :utc_datetime_usec, null: false
      add :removed_at, :utc_datetime_usec
    end

    create index(:helper_records, [:parent, :id])
    create index(:helper_records, [:agent_id, :removed_at])

    execute "INSERT INTO helper_records (agent_id, parent, spawned_at) SELECT agent_id, parent, spawned_at FROM sub_agents", "DELETE FROM helper_records"
  end
end
