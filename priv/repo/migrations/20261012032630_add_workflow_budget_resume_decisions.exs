defmodule Custode.Repo.Migrations.AddWorkflowBudgetResumeDecisions do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add(:budget_pause_id, :string)
      add(:budget_paused_at, :utc_datetime_usec)
      add(:budget_resume_pending, :string)
    end

    create table(:workflow_budget_resumes) do
      add(
        :run_id,
        references(:workflow_runs, column: :run_id, type: :string, on_delete: :delete_all),
        null: false
      )

      add(:pause_id, :string, null: false)
      add(:previous_budget_usd, :float)
      add(:budget_usd, :float)
      add(:actor_id, :string, null: false)
      add(:via, :string, null: false)
      add(:admitted_at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:workflow_budget_resumes, [:run_id, :pause_id]))

    # Preserve unknown historical pause time. A reference grants no approval.
    execute(
      "UPDATE workflow_runs SET budget_pause_id = 'wbp-' || lower(hex(randomblob(16))) WHERE status = 'budget_paused'",
      "UPDATE workflow_runs SET budget_pause_id = NULL"
    )
  end
end
