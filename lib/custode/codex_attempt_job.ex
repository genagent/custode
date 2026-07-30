defmodule Custode.CodexAttemptJob do
  @moduledoc """
  ID-only physical delivery for one bounded Codex Attempt.

  Completed jobs remain unique forever because a semantic retry is a new
  Attempt, never another delivery of this one.
  """

  use Oban.Worker,
    queue: :agents,
    max_attempts: 3,
    unique: [
      fields: [:worker, :args],
      period: :infinity,
      states: [
        :available,
        :scheduled,
        :executing,
        :retryable,
        :suspended,
        :completed,
        :discarded,
        :cancelled
      ]
    ]

  alias Custode.CodexAttempts

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: CodexAttempts.perform(job)
end
