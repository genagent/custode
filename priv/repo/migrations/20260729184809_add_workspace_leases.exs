defmodule Custode.Repo.Migrations.AddWorkspaceLeases do
  use Ecto.Migration

  def change do
    create table(:workspace_leases) do
      add(:lease_id, :string, null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:attempt_id, references(:attempts, on_delete: :restrict), null: false)
      add(:repository_id, :string, null: false)
      add(:repository_path, :text, null: false)
      add(:workspace_identity, :string, null: false)
      add(:workspace_path, :text, null: false)
      add(:branch, :string, null: false)
      add(:base_ref, :string, null: false)
      add(:expected_base_revision, :string, null: false)
      add(:observed_base_revision, :string)
      add(:landing_scope, :string, null: false)
      add(:state, :string, null: false, default: "acquiring")
      add(:cleanup_state, :string, null: false, default: "pending")
      add(:provenance, :map, null: false, default: %{})
      add(:acquired_at, :utc_datetime_usec, null: false)
      add(:heartbeat_at, :utc_datetime_usec, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:prepared_at, :utc_datetime_usec)
      add(:released_at, :utc_datetime_usec)
      add(:cleanup_error, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:workspace_leases, [:lease_id]))
    create(unique_index(:workspace_leases, [:attempt_id]))

    create(
      unique_index(:workspace_leases, [:work_item_id],
        name: :workspace_leases_live_work_item_index,
        where: "state IN ('acquiring', 'active')"
      )
    )

    create(
      unique_index(:workspace_leases, [:landing_scope],
        name: :workspace_leases_live_landing_scope_index,
        where: "state IN ('acquiring', 'active')"
      )
    )

    create(
      unique_index(:workspace_leases, [:workspace_path],
        name: :workspace_leases_live_path_index,
        where: "state IN ('acquiring', 'active')"
      )
    )

    create(index(:workspace_leases, [:mission_id, :state]))
    create(index(:workspace_leases, [:work_item_id, :state]))
    create(index(:workspace_leases, [:repository_id, :state]))
    create(index(:workspace_leases, [:expires_at, :state]))
  end
end
