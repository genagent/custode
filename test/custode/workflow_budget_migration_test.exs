defmodule Custode.WorkflowBudgetMigrationTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers, only: [tmp_workspace!: 0]
  alias Ecto.Adapters.SQL

  defmodule MigrationRepo do
    use Ecto.Repo, otp_app: :custode, adapter: Ecto.Adapters.SQLite3
  end

  test "migration gives existing pauses stable references without approvals or invented dates" do
    directory = tmp_workspace!()

    start_supervised!(
      {MigrationRepo, database: Path.join(directory, "migration.db"), pool_size: 1}
    )

    query = &SQL.query!(MigrationRepo, &1, [])

    query.(
      "CREATE TABLE workflow_runs (id INTEGER PRIMARY KEY, run_id TEXT NOT NULL UNIQUE, status TEXT NOT NULL)"
    )

    query.(
      "INSERT INTO workflow_runs (run_id, status) VALUES ('parked', 'budget_paused'), ('active', 'running'), ('done', 'complete')"
    )

    migration = Custode.Repo.Migrations.AddWorkflowBudgetResumeDecisions

    unless Code.ensure_loaded?(migration) do
      Code.require_file(
        "priv/repo/migrations/20261012032630_add_workflow_budget_resume_decisions.exs"
      )
    end

    version = 20_261_012_032_630
    assert :ok = Ecto.Migrator.up(MigrationRepo, version, migration, log: false)

    assert [["parked", pause, nil, nil]] =
             query.(
               "SELECT run_id, budget_pause_id, budget_paused_at, budget_resume_pending FROM workflow_runs WHERE status = 'budget_paused'"
             ).rows

    assert pause =~ ~r/^wbp-[0-9a-f]{32}$/
    assert [[0]] = query.("SELECT count(*) FROM workflow_budget_resumes").rows

    assert [[2]] =
             query.(
               "SELECT count(*) FROM workflow_runs WHERE status != 'budget_paused' AND budget_pause_id IS NULL"
             ).rows

    assert :already_up = Ecto.Migrator.up(MigrationRepo, version, migration, log: false)

    assert [[^pause]] =
             query.("SELECT budget_pause_id FROM workflow_runs WHERE run_id = 'parked'").rows

    assert :ok = Ecto.Migrator.down(MigrationRepo, version, migration, log: false)
    assert [[3]] = query.("SELECT count(*) FROM workflow_runs").rows
  end
end
