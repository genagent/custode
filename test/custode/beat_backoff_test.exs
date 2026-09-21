defmodule Custode.BeatBackoffTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.BeatBackoff
  alias Custode.Feed
  alias Custode.Feed.Ingest
  alias Custode.NextBeat

  @now ~U[2026-09-21 10:00:00Z]

  defp routine!(cron) do
    id = uid("backoff")
    put_env!(:routines, [%{id: id, cron: cron, workspace: "/tmp/" <> id, prompt: "sweep"}])
    id
  end

  defp failed!(id, category \\ :timeout) do
    Feed.record(%{event: "turn_failed", agent: id, category: category, retryable: true})
  end

  defp fail_turn(id, error) do
    Ingest.handle_event(
      [:oban_claude, :run, :exception],
      %{},
      %{job: %{meta: %{"agent_id" => id}}, error: error},
      nil
    )
  end

  defp transition(id, from, to) do
    meta = %{agent_id: id, from: from, to: to}
    NextBeat.handle_event([:oban_claude, :agent, :transition], %{}, meta, nil)
  end

  defp backoffs(id), do: Feed.recent_by_event("beat_backoff", agent: id)

  describe "interval_minutes/2" do
    test "is the distance between the cron's next two fires" do
      assert BeatBackoff.interval_minutes("*/15 * * * *", @now) == 15
      assert BeatBackoff.interval_minutes("@hourly", @now) == 60
      assert BeatBackoff.interval_minutes("@daily", @now) == 1440
    end

    test "falls back when the cron has no interval" do
      assert BeatBackoff.interval_minutes(:manual, @now) == 60
      assert BeatBackoff.interval_minutes("@reboot", @now) == 60
      assert BeatBackoff.interval_minutes("not a cron", @now) == 60
    end
  end

  describe "wait_minutes/3" do
    test "doubles per consecutive failure up to the bounds maximum" do
      put_env!(:next_beat_bounds, {5, 100})
      waits = for n <- 1..5, do: BeatBackoff.wait_minutes("*/15 * * * *", n, @now)
      assert waits == [15, 30, 60, 100, 100]
      assert BeatBackoff.wait_minutes("*/15 * * * *", 10_000, @now) == 100
    end
  end

  describe "after_failure/3" do
    test "a retryable failure sets the next beat and says so in the feed" do
      id = routine!("*/15 * * * *")
      failed!(id)

      assert {:ok, %{minutes: 15, failures: 1}} =
               BeatBackoff.after_failure(id, :timeout, now: @now)

      assert DateTime.compare(NextBeat.get(id).at, ~U[2026-09-21 10:15:00Z]) == :eq

      failed!(id, :rate_limited)

      assert {:ok, %{minutes: 30, failures: 2}} =
               BeatBackoff.after_failure(id, :rate_limited, now: @now)

      assert [%{"minutes" => 30, "failures" => 2, "category" => "rate_limited"}, _first] =
               backoffs(id)
    end

    test "a successful turn ends the run, with no reset code" do
      id = routine!("*/15 * * * *")
      failed!(id)
      failed!(id)
      Feed.record(%{event: "turn", agent: id, summary: "fine"})
      failed!(id)

      assert {:ok, %{minutes: 15, failures: 1}} =
               BeatBackoff.after_failure(id, :timeout, now: @now)
    end

    test "an entry with no category neither counts nor breaks the run" do
      id = routine!("*/15 * * * *")
      failed!(id)
      Feed.record(%{event: "turn_failed", agent: id, kind: "drain_timeout"})
      failed!(id)

      assert {:ok, %{failures: 2}} = BeatBackoff.after_failure(id, :timeout, now: @now)
    end

    test "a non-retryable category does not back off" do
      id = routine!("*/15 * * * *")
      failed!(id, :auth_failed)

      assert BeatBackoff.after_failure(id, :auth_failed, now: @now) == :noop
      assert NextBeat.get(id) == nil
      assert backoffs(id) == []
    end

    test "only a routine backs off" do
      routine!("*/15 * * * *")
      stranger = uid("sub-agent")
      failed!(stranger)

      assert BeatBackoff.after_failure(stranger, :timeout, now: @now) == :noop
      assert NextBeat.get(stranger) == nil
    end

    test "the agent's own later request is kept, an earlier one is replaced" do
      id = routine!("*/15 * * * *")
      failed!(id)

      {:ok, %{at: own}} = NextBeat.request(id, 120, now: @now, reason: "release tomorrow")
      assert BeatBackoff.after_failure(id, :timeout, now: @now) == :noop
      assert NextBeat.get(id).at == own
      assert backoffs(id) == []

      NextBeat.request(id, 6, now: @now)
      assert {:ok, %{minutes: 15}} = BeatBackoff.after_failure(id, :timeout, now: @now)
      assert NextBeat.get(id).reason =~ "backoff"
    end

    test "config :beat_backoff, false switches it off" do
      put_env!(:beat_backoff, false)
      id = routine!("*/15 * * * *")
      failed!(id)

      assert BeatBackoff.after_failure(id, :timeout, now: @now) == :noop
      assert NextBeat.get(id) == nil
    end
  end

  describe "through the telemetry handlers" do
    test "the failed turn's backoff survives leaving :running, and the next turn start clears it" do
      id = routine!("*/15 * * * *")

      # the order the engine emits: the turn starts, fails, the agent idles
      transition(id, :idle, :running)
      fail_turn(id, %ClaudeWrapper.Error{kind: :timeout, message: "timed out"})
      transition(id, :running, :idle)

      assert %NextBeat{reason: reason} = NextBeat.get(id)
      assert reason =~ "timeout"
      assert [%{"failures" => 1, "category" => "timeout"}] = backoffs(id)

      # an operator message, a sensor wake, the backoff's own beat: all of them
      transition(id, :idle, :running)
      assert NextBeat.get(id) == nil
    end

    test "a terminal failure records turn_failed and no backoff" do
      id = routine!("*/15 * * * *")
      fail_turn(id, %ClaudeWrapper.Error{kind: :auth, reason: :expired, message: "logged out"})

      assert [%{"category" => "auth_failed"}] = Feed.recent_by_event("turn_failed", agent: id)
      assert NextBeat.get(id) == nil
    end
  end
end
