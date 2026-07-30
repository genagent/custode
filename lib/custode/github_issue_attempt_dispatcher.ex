defmodule Custode.GitHubIssueAttemptDispatcher do
  @moduledoc "Compatibility facade for capability-based Attempt dispatch."

  alias Custode.AttemptPool

  def admit(attempt, options), do: AttemptPool.admit(attempt, options)

  def dispatch(attempt, oban_job_id, options),
    do: AttemptPool.dispatch(attempt, oban_job_id, options)
end
