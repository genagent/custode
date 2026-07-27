defmodule Custode.Repo.Migrations.AddWorkflowRunBudget do
  use Ecto.Migration

  # The run-level budget rail (#271, design/005 slice 2 point 5). A run is a
  # deliberately expensive many-node dig, so it carries its OWN ceiling
  # alongside the per-node cap and the routines' daily rails: crossing it
  # parks the run at `budget_paused` rather than letting a fan-out that
  # expanded wider than anyone expected run to the end.
  #
  # Nullable: a run launched without a rail (iex, tests) is unbounded, which
  # is what slice 1b already did. The launch gate always sets one.
  def change do
    alter table(:workflow_runs) do
      add(:budget_usd, :float)
    end
  end
end
