defmodule Custode.Repo.Migrations.AddWorkflowNodeResults do
  use Ecto.Migration

  # Workflow node results (#271, design/005). One row per completed node of a
  # workflow run, keyed by {workflow_run, node_name, args_hash}: that key is
  # what makes a run resumable (enqueue only the nodes with no row) and what
  # makes an edited workflow re-run only what changed (a node's hash covers
  # its rendered inputs, so an upstream edit invalidates everything below it).
  #
  # The structured result lives here as JSON (it is queried back on every
  # stage barrier -- a record, design/002). A long report a node writes stays
  # a file in the workspace; `artifact` holds its path.
  def change do
    create table(:workflow_node_results) do
      add(:workflow_run, :string, null: false)
      add(:workflow, :string, null: false)
      add(:stage, :string, null: false)
      add(:node_name, :string, null: false)
      add(:args_hash, :string, null: false)
      # the node's --json-schema output as JSON (string keys)
      add(:result, :text, null: false)
      # path to a report artifact in the workspace, when the node wrote one
      add(:artifact, :string)
      add(:at, :utc_datetime_usec, null: false)
    end

    # the identity of a node result; upserts target it
    create(unique_index(:workflow_node_results, [:workflow_run, :node_name, :args_hash]))
    create(index(:workflow_node_results, [:workflow_run, :stage]))
  end
end
