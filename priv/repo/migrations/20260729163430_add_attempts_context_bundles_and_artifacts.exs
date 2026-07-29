defmodule Custode.Repo.Migrations.AddAttemptsContextBundlesAndArtifacts do
  use Ecto.Migration

  def change do
    create table(:artifacts) do
      add(:artifact_id, :string, null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:kind, :string, null: false)
      add(:provenance, :map, null: false, default: %{})
      add(:external_identity, :string)
      add(:digest, :string)
      add(:media_type, :string, null: false)
      add(:location, :text, null: false)
      add(:size_bytes, :integer, null: false)
      add(:retention, :map, null: false, default: %{})
      add(:expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:artifacts, [:artifact_id]))
    create(unique_index(:artifacts, [:external_identity], where: "external_identity IS NOT NULL"))
    create(index(:artifacts, [:work_item_id, :kind]))
    create(index(:artifacts, [:mission_id]))
    create(index(:artifacts, [:digest]))

    create table(:context_bundles) do
      add(:context_bundle_id, :string, null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:artifact_id, references(:artifacts, on_delete: :restrict), null: false)
      add(:version, :integer, null: false, default: 1)
      add(:digest, :string, null: false)
      add(:component_digests, :map, null: false)
      add(:provenance, :map, null: false, default: %{})
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:context_bundles, [:context_bundle_id]))
    create(unique_index(:context_bundles, [:work_item_id, :digest]))
    create(index(:context_bundles, [:mission_id]))
    create(index(:context_bundles, [:artifact_id]))

    create table(:attempts) do
      add(:attempt_id, :string, null: false)
      add(:work_item_id, references(:work_items, on_delete: :restrict), null: false)
      add(:role_binding_id, references(:role_bindings, on_delete: :restrict))
      add(:context_bundle_id, references(:context_bundles, on_delete: :restrict), null: false)
      add(:caused_by_attempt_id, references(:attempts, on_delete: :restrict))
      add(:executor_kind, :string, null: false)
      add(:provider, :string, null: false)
      add(:profile, :string, null: false)
      add(:recipe_version, :string, null: false)
      add(:state, :string, null: false, default: "queued")
      add(:context_digest, :string, null: false)
      add(:oban_job_id, :integer)
      add(:workflow_run_id, :string)
      add(:provider_continuation, :map)
      add(:expected_work_item_version, :integer, null: false)
      add(:provenance, :map, null: false, default: %{})
      add(:started_at, :utc_datetime_usec)
      add(:finished_at, :utc_datetime_usec)
      add(:usage, :map, null: false, default: %{})
      add(:outcome, :map)
      add(:error_class, :string)
      add(:error_details, :map)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:attempts, [:attempt_id]))
    create(unique_index(:attempts, [:oban_job_id], where: "oban_job_id IS NOT NULL"))
    create(index(:attempts, [:work_item_id, :state]))
    create(index(:attempts, [:role_binding_id]))
    create(index(:attempts, [:context_bundle_id]))
    create(index(:attempts, [:caused_by_attempt_id]))
    create(index(:attempts, [:workflow_run_id]))

    alter table(:artifacts) do
      add(:producer_attempt_id, references(:attempts, on_delete: :restrict))
    end

    create(index(:artifacts, [:producer_attempt_id]))

    alter table(:workflow_runs) do
      add(
        :work_item_id,
        references(:work_items,
          column: :work_item_id,
          type: :string,
          on_delete: :restrict
        )
      )
    end

    create(index(:workflow_runs, [:work_item_id]))

    alter table(:workflow_node_results) do
      add(
        :attempt_id,
        references(:attempts,
          column: :attempt_id,
          type: :string,
          on_delete: :restrict
        )
      )
    end

    create(index(:workflow_node_results, [:attempt_id]))

    alter table(:spend) do
      add(:attempt_id, :string)
      add(:work_item_id, :string)
      add(:mission_id, :string)
      add(:provider, :string)
      add(:legacy_routine_id, :string)
    end

    create(index(:spend, [:attempt_id]))
    create(index(:spend, [:work_item_id]))
    create(index(:spend, [:mission_id]))
    create(index(:spend, [:provider]))
    create(index(:spend, [:legacy_routine_id]))
  end
end
