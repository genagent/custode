defmodule Custode.CodexAttempts do
  @moduledoc """
  Codex entry point for provider-neutral model Attempt orchestration.

  The immutable Attempt selects Codex before this facade creates or executes
  physical delivery.
  """

  alias Custode.ModelAttempts

  def dispatch(attempt_id, routine_id, options \\ []) do
    ModelAttempts.dispatch(
      attempt_id,
      routine_id,
      Keyword.put(options, :expected_provider, "codex")
    )
  end

  def perform(%Oban.Job{} = job),
    do: ModelAttempts.perform(job, expected_provider: "codex")

  def perform(%Oban.Job{} = job, options) when is_list(options),
    do: ModelAttempts.perform(job, Keyword.put(options, :expected_provider, "codex"))
end
