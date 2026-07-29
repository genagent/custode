defmodule Custode.WorkCommandJob do
  @moduledoc """
  Physical delivery for one durable WorkItem next-action claim.

  Arguments intentionally contain only stable IDs and an expected version.
  """

  use Oban.Worker,
    queue: :agents,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended, :completed]
    ]

  alias Custode.WorkProcess

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{
          "decision_id" => decision_id,
          "work_item_id" => work_item_id,
          "expected_version" => expected_version
        }
      }) do
    WorkProcess.perform(decision_id, work_item_id, expected_version, job_id)
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_work_command}
end
