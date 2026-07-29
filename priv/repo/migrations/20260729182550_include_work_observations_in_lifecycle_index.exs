defmodule Custode.Repo.Migrations.IncludeWorkObservationsInLifecycleIndex do
  use Ecto.Migration

  def change do
    drop(
      unique_index(:work_events, [:work_item_id, :work_item_version],
        name: :work_events_lifecycle_version_index
      )
    )

    create(
      unique_index(:work_events, [:work_item_id, :work_item_version],
        name: :work_events_lifecycle_version_index,
        where:
          "kind IN ('work_item.created', 'work_item.transitioned', 'work_item.reopened', 'work_item.observed')"
      )
    )
  end
end
