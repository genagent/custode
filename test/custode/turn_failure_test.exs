defmodule Custode.TurnFailureTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Error
  alias Custode.TurnFailure

  doctest Custode.TurnFailure

  @retryable [:timeout, :rate_limited, :unknown_harness_error]
  @terminal [:process_crash, :auth_failed, :capability_refused, :config_error]

  test "seven categories, three of them retryable" do
    assert TurnFailure.categories() == @retryable ++ @terminal
    assert Enum.filter(TurnFailure.categories(), &TurnFailure.retryable?/1) == @retryable
  end

  test "every kind maps from the typed field" do
    expected = %{
      timeout: :timeout,
      command_failed: :unknown_harness_error,
      json: :unknown_harness_error,
      no_structured_output: :unknown_harness_error,
      io: :process_crash,
      terminated: :process_crash,
      duplex_closed: :process_crash,
      max_turns_exceeded: :capability_refused,
      max_budget_exceeded: :capability_refused,
      budget_exceeded: :capability_refused,
      dangerous_not_allowed: :capability_refused,
      binary_not_found: :config_error,
      version_mismatch: :config_error,
      invalid_settings_json: :config_error,
      settings_read_error: :config_error,
      invalid_tool_pattern: :config_error
    }

    for {kind, category} <- expected do
      assert TurnFailure.classify(%Error{kind: kind}) == category, "#{kind}"
    end
  end

  test "auth splits on its typed reason: a rate limit clears, a login does not" do
    assert TurnFailure.classify(%Error{kind: :auth, reason: :rate_limit}) == :rate_limited

    for reason <- [:not_authenticated, :expired, :invalid_credentials, :provider_error, :other] do
      assert TurnFailure.classify(%Error{kind: :auth, reason: reason}) == :auth_failed
    end
  end

  test "prose is never read: an auth-shaped message on an untyped exit stays unknown" do
    error = %Error{kind: :command_failed, exit_code: 1, stderr: "401 Unauthorized, please login"}

    assert TurnFailure.classify(error) == :unknown_harness_error
  end

  test "a kind this module has never seen is retryable, not an alarm" do
    assert TurnFailure.classify(%Error{kind: :something_new}) == :unknown_harness_error
  end

  test "anything that is not the wrapper's error is the process dying around it" do
    assert TurnFailure.classify(%RuntimeError{message: "boom"}) == :process_crash
    assert TurnFailure.classify(:killed) == :process_crash
  end

  test "only a non-retryable category has a remedy" do
    for category <- @terminal, do: assert(is_binary(TurnFailure.remedy(category)))
    for category <- @retryable, do: assert(TurnFailure.remedy(category) == nil)
    assert TurnFailure.remedy(:auth_failed) =~ "claude is not logged in on this host"
  end

  test "from_entry/1 reads the feed's string back, and nothing else" do
    assert TurnFailure.from_entry(%{"category" => "auth_failed"}) == :auth_failed
    assert TurnFailure.from_entry(%{"category" => "made_up"}) == nil
    assert TurnFailure.from_entry(%{"kind" => "drain_timeout"}) == nil
  end
end
