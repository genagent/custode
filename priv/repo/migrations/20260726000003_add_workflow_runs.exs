defmodule Custode.Repo.Migrations.AddWorkflowRuns do
  use Ecto.Migration

  # One row per workflow run (#271, design/005 slice 1b). The node results
  # table says what has finished; this says what is being run at all -- which
  # workflow, against which repo, how far it has got, and whether it is still
  # going. Without it a run id is unresolvable: a fresh process could not tell
  # which catalog entry a half-finished set of results belongs to.
  #
  # A record by design/002's test: the runner queries it back on every node
  # completion to decide what to enqueue next.
  def change do
    create table(:workflow_runs) do
      add(:run_id, :string, null: false)
      add(:workflow, :string, null: false)
      add(:repo, :string, null: false)
      # running | complete | failed
      add(:status, :string, null: false)
      # the stage the runner is currently filling; nil once the run is done
      add(:stage, :string)
      # extra render bindings supplied at launch, as JSON
      add(:context, :text, null: false)
      # what the run could not do, appended as JSON strings: an empty fan-out,
      # a node whose result did not honour its schema. A finished run says what
      # it skipped rather than reading as if it covered everything.
      add(:notes, :text, null: false)
      add(:error, :text)
      add(:started_at, :utc_datetime_usec, null: false)
      add(:finished_at, :utc_datetime_usec)
    end

    create(unique_index(:workflow_runs, [:run_id]))
    create(index(:workflow_runs, [:status]))
  end
end
