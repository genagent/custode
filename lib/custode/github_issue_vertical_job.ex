defmodule Custode.GitHubIssueVerticalJob do
  @moduledoc """
  ID-only physical delivery for the bounded GitHub issue vertical.

  Intake may observe the same issue repeatedly. Uniqueness keeps one live
  coordinator while durable WorkItem and Attempt identities provide the
  logical idempotency.
  """

  use Oban.Worker,
    queue: :agents,
    max_attempts: 5,
    unique: [
      fields: [:worker, :args],
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended]
    ]

  alias Custode.GitHubIssueVertical

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{"routine_id" => routine_id, "work_item_id" => work_item_id}
      }) do
    GitHubIssueVertical.perform(routine_id, work_item_id, oban_job_id: job_id)
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_github_issue_vertical}
end
