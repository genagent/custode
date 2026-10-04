defmodule Custode.Repo.Migrations.CaptureWorkflowExecutionIdentity do
  use Ecto.Migration

  def change do
    alter table(:workflow_runs) do
      add :execution_generation, :string
      add :definition_snapshot, :text
      add :failure_identity, :text
    end
  end
end
