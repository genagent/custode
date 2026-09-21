defmodule Custode.TurnFailure do
  @moduledoc """
  Why a turn failed, as one of seven categories (#527).

  A `turn_failed` feed entry carried the wrapper's `kind` and a slice of
  stderr, and every reader drew its own conclusion from them. The conclusion
  that matters is whether the next beat can succeed on its own. A timeout
  can; a logged-out `claude` cannot, and a fleet that fails every turn for
  that reason reads as alive on every page (#443 was this, found after three
  days).

  `classify/1` reads the error's TYPED fields, `kind` and `reason`, never its
  message or stderr. Where the wrapper has already parsed prose into a type
  (`ClaudeWrapper.Auth.classify_failure/3` behind `kind: :auth`), that type is
  what is read. A failure with no typed cause is `:unknown_harness_error`,
  which is retryable: guessing from text is how a category stops being
  trusted.

  ## Categories

  | category | retryable | from |
  | -------- | --------- | ---- |
  | `:timeout` | yes | `kind: :timeout` |
  | `:rate_limited` | yes | `kind: :auth, reason: :rate_limit` |
  | `:unknown_harness_error` | yes | `:command_failed`, `:json`, any kind not listed |
  | `:process_crash` | no | `:io`, `:terminated`, `:duplex_closed`, anything that is not a `ClaudeWrapper.Error` |
  | `:auth_failed` | no | `kind: :auth` with any other reason |
  | `:capability_refused` | no | a cap or an opt-in refused the turn: `:max_turns_exceeded`, `:max_budget_exceeded`, `:budget_exceeded`, `:dangerous_not_allowed` |
  | `:config_error` | no | the host or the settings are wrong: `:binary_not_found`, `:version_mismatch`, `:invalid_settings_json`, ... |

  `:command_failed` is retryable because the wrapper's own retry policy treats
  a bare non-zero exit as transient (`ClaudeWrapper.Retry`), and a recognized
  auth or rate-limit exit never arrives as `:command_failed`.
  """

  @type category ::
          :timeout
          | :rate_limited
          | :unknown_harness_error
          | :process_crash
          | :auth_failed
          | :capability_refused
          | :config_error

  @retryable [:timeout, :rate_limited, :unknown_harness_error]
  @terminal [:process_crash, :auth_failed, :capability_refused, :config_error]

  @crash_kinds [:io, :terminated, :duplex_closed]
  @refused_kinds [
    :max_turns_exceeded,
    :max_budget_exceeded,
    :budget_exceeded,
    :dangerous_not_allowed
  ]
  @config_kinds [
    :binary_not_found,
    :version_mismatch,
    :invalid_version,
    :invalid_settings_json,
    :settings_read_error,
    :invalid_tool_pattern,
    :no_home,
    :not_a_git_repo,
    :git_unavailable
  ]

  @doc "Every category, retryable ones first."
  @spec categories() :: [category()]
  def categories, do: @retryable ++ @terminal

  @doc """
  The category of whatever a failed run carried as its error.

      iex> Custode.TurnFailure.classify(%ClaudeWrapper.Error{kind: :timeout})
      :timeout
      iex> Custode.TurnFailure.classify(%ClaudeWrapper.Error{kind: :auth, reason: :rate_limit})
      :rate_limited
      iex> Custode.TurnFailure.classify(%ClaudeWrapper.Error{kind: :auth, reason: :expired})
      :auth_failed
      iex> Custode.TurnFailure.classify({:EXIT, :killed})
      :process_crash
  """
  @spec classify(term()) :: category()
  def classify(%ClaudeWrapper.Error{kind: :timeout}), do: :timeout
  def classify(%ClaudeWrapper.Error{kind: :auth, reason: :rate_limit}), do: :rate_limited
  def classify(%ClaudeWrapper.Error{kind: :auth}), do: :auth_failed
  def classify(%ClaudeWrapper.Error{kind: kind}) when kind in @crash_kinds, do: :process_crash

  def classify(%ClaudeWrapper.Error{kind: kind}) when kind in @refused_kinds,
    do: :capability_refused

  def classify(%ClaudeWrapper.Error{kind: kind}) when kind in @config_kinds, do: :config_error
  def classify(%ClaudeWrapper.Error{}), do: :unknown_harness_error
  # Not the wrapper's error at all: the worker raised or exited around it.
  def classify(_other), do: :process_crash

  @doc """
  Whether the next beat can succeed with nobody doing anything.

      iex> Custode.TurnFailure.retryable?(:timeout)
      true
      iex> Custode.TurnFailure.retryable?(:auth_failed)
      false
  """
  @spec retryable?(category()) :: boolean()
  def retryable?(category), do: category in @retryable

  @doc """
  The category a feed entry recorded, or `nil` for an entry that predates the
  field or names something this module does not know. The feed stores strings;
  this is the one place they come back as atoms.
  """
  @spec from_entry(map()) :: category() | nil
  def from_entry(%{"category" => name}) when is_binary(name),
    do: Enum.find(categories(), &(Atom.to_string(&1) == name))

  def from_entry(_entry), do: nil

  @doc """
  The trailing run of failed turns in `agent_id`'s feed, newest first: every
  `turn_failed` since the last `turn`. Empty once a turn has succeeded.

  Only entries carrying a `category` count as outcomes. `turn_failed` is also
  recorded for things that are not turns (a drain timeout, an undeliverable
  orphan notice), and those neither start nor break a run. One read, shared by
  `:turn_failing` (#527) and the beat backoff (#543).
  """
  @spec streak(String.t()) :: [map()]
  def streak(agent_id) do
    agent_id
    |> Custode.Feed.for_agent(50)
    |> Enum.reverse()
    |> Enum.filter(&outcome?/1)
    |> Enum.take_while(&(&1["event"] == "turn_failed"))
  end

  # A `beat_backoff` entry carries a category too (#543) and is not an outcome.
  defp outcome?(%{"event" => "turn"}), do: true
  defp outcome?(%{"event" => "turn_failed"} = entry), do: from_entry(entry) != nil
  defp outcome?(_entry), do: false

  @doc """
  What the operator must do about a failure that will not clear by itself, as
  a headline. `nil` for a retryable category: nothing is owed.
  """
  @spec remedy(category()) :: String.t() | nil
  def remedy(:auth_failed), do: "claude is not logged in on this host -- run `claude login`"
  def remedy(:config_error), do: "claude cannot start here -- fix the host or the settings"

  def remedy(:capability_refused),
    do: "turns stop at a cap -- raise max_turns or the budget, or narrow the work"

  def remedy(:process_crash), do: "the claude process keeps dying -- read the error"
  def remedy(_retryable), do: nil
end
