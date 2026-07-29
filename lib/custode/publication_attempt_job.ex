defmodule Custode.PublicationAttemptJob do
  @moduledoc "ID-only physical delivery for one deterministic publication Attempt."

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

  alias Custode.PublicationAttempts

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: PublicationAttempts.perform(job)
end
