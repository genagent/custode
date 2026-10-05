defmodule Custode.Repo.Migrations.RetainWorkflowResultValidation do
  use Ecto.Migration

  def change do
    alter table(:workflow_node_results) do
      add(:validation, :map)
    end
  end
end
