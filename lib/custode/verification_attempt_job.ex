defmodule Custode.VerificationAttemptJob do
  @moduledoc "ID-only physical delivery for one deterministic verification Attempt."

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

  alias Custode.VerificationAttempts

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: VerificationAttempts.perform(job)
end
