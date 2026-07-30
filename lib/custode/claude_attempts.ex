defmodule Custode.ClaudeAttempts do
  @moduledoc """
  Compatibility entry point for Claude-backed model Attempts.

  Durable orchestration is shared in `Custode.ModelAttempts`; this facade pins
  the physical delivery to the provider selected by the immutable Attempt.
  """

  alias Custode.ModelAttempts

  def dispatch(attempt_id, routine_id, options \\ []) do
    ModelAttempts.dispatch(
      attempt_id,
      routine_id,
      Keyword.put(options, :expected_provider, "claude")
    )
  end

  def perform(%Oban.Job{} = job),
    do: ModelAttempts.perform(job, expected_provider: "claude")

  def perform(%Oban.Job{} = job, options) when is_list(options),
    do: ModelAttempts.perform(job, Keyword.put(options, :expected_provider, "claude"))
end
