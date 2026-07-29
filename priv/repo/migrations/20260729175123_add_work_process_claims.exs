defmodule Custode.Repo.Migrations.AddWorkProcessClaims do
  use Ecto.Migration

  def change do
    create(
      unique_index(:work_events, [:work_item_id, :work_item_version],
        name: :work_events_next_action_claim_index,
        where: "kind = 'work.next_action.claimed'"
      )
    )

    create(
      unique_index(:work_events, [:causation_id],
        name: :work_events_next_action_result_index,
        where: "kind = 'work.next_action.completed'"
      )
    )
  end
end
