defmodule Custode.Repo.Migrations.RetainWorkflowRunnerObservations do
  use Ecto.Migration

  def change do
    create table(:workflow_runner_observations, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:workflow_run, :string, null: false)
      add(:job_id, :integer, null: false)
      add(:job_attempt, :integer, null: false)
      add(:execution_generation, :string, null: false)
      add(:binding, :map, null: false)
      add(:request, :map, null: false)
      add(:request_sha256, :string, null: false)
      add(:requested_at, :utc_datetime_usec, null: false)
      add(:transport_return, :map)
      add(:returned_at, :utc_datetime_usec)
    end

    create(
      unique_index(:workflow_runner_observations, [:job_id, :job_attempt, :execution_generation])
    )

    create(index(:workflow_runner_observations, [:workflow_run, :requested_at]))
  end
end
