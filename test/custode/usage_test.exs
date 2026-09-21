defmodule Custode.UsageTest do
  # the availability store is one ETS table
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ExUnit.CaptureLog

  alias Custode.Availability
  alias Custode.Availability.Collectors.Claude
  alias Custode.Availability.Probe

  @now ~U[2026-09-20 03:50:00.000000Z]

  # captured verbatim from `claude` 2.1.273 on a Max plan, 2026-09-19 (#458)
  @event %{
    "type" => "rate_limit_event",
    "rate_limit_info" => %{
      "status" => "allowed",
      "resetsAt" => 1_789_892_400,
      "rateLimitType" => "five_hour",
      "overageStatus" => "rejected",
      "overageDisabledReason" => "out_of_credits",
      "isUsingOverage" => false,
      "unifiedWindows" => %{
        "five_hour" => %{"utilization" => 0.12, "resetsAt" => 1_789_892_400},
        "seven_day" => %{"utilization" => 0.41, "resetsAt" => 1_790_218_800}
      }
    }
  }

  setup do
    Availability.forget(:all)
    on_exit(fn -> Availability.forget(:all) end)
    :ok
  end

  describe "the collector reads a real event" do
    test "both windows, as fractions, with unix resets, the wrapper unwrapped" do
      {:ok, snapshot} = Claude.observe(@event, now: @now)

      buckets = Map.new(snapshot.buckets, &{&1.id, &1})
      assert buckets["five_hour"].utilization == 0.12
      assert buckets["seven_day"].utilization == 0.41
      assert buckets["five_hour"].resets_at == DateTime.from_unix!(1_789_892_400)
      assert buckets["seven_day"].resets_at == DateTime.from_unix!(1_790_218_800)
      assert buckets["five_hour"].status == :ok
      assert buckets["seven_day"].status == :ok
    end

    test "the event's one status belongs to the window it names, not to all of them" do
      rejected =
        @event
        |> put_in(["rate_limit_info", "status"], "rejected")
        |> put_in(["rate_limit_info", "rateLimitType"], "seven_day")

      {:ok, snapshot} = Claude.observe(rejected, now: @now)
      buckets = Map.new(snapshot.buckets, &{&1.id, &1})

      assert buckets["seven_day"].status == :rejected
      assert buckets["five_hour"].status == :ok
    end
  end

  describe "usage/2, what a page draws" do
    test "unknown is unknown, never zero percent" do
      assert Availability.usage("claude", now: @now) ==
               %{
                 freshness: :unknown,
                 observed_at: nil,
                 age_seconds: nil,
                 held_until: nil,
                 windows: []
               }
    end

    test "labels the windows and puts the shortest first, because it bites first" do
      {:ok, _snapshot} = Claude.observe(@event, now: @now)

      assert %{freshness: :fresh, windows: [five, seven]} =
               Availability.usage("claude", now: @now)

      assert %{label: "5h", utilization: 0.12} = five
      assert %{label: "7d", utilization: 0.41} = seven
    end

    test "an old observation is stale, and says so" do
      {:ok, _snapshot} = Claude.observe(@event, now: @now)
      later = DateTime.add(@now, 3_600, :second)

      assert Availability.usage("claude", now: later).freshness == :stale
    end
  end

  describe "the probe" do
    test "takes the rate_limit_event out of a run's stream and records it" do
      Custode.PubSubBridge.subscribe()

      put_env!(:usage_probe_fun, fn ->
        [
          %{type: "system", data: %{}},
          %{type: "rate_limit_event", data: @event},
          %{type: "result", data: %{"result" => "ok"}}
        ]
      end)

      assert {:ok, _snapshot} = Probe.run(now: @now)
      assert [%{label: "5h"}, %{label: "7d"}] = Availability.usage("claude", now: @now).windows
      assert_receive {:usage_changed, "claude"}
    end

    test "skips itself when the snapshot is already fresh, and runs when forced" do
      test_pid = self()
      {:ok, _snapshot} = Claude.observe(@event, now: @now)

      put_env!(:usage_probe_fun, fn ->
        send(test_pid, :probed)
        [%{type: "rate_limit_event", data: @event}]
      end)

      assert Probe.run(now: @now) == :fresh
      refute_receive :probed, 50

      assert {:ok, _snapshot} = Probe.run(now: @now, force: true)
      assert_receive :probed
    end

    # absence advises proceeding: a broken probe is an empty header, not an outage
    test "a run with no event, or a run that raises, records nothing and says so" do
      put_env!(:usage_probe_fun, fn -> [%{type: "result", data: %{}}] end)
      log = capture_log(fn -> assert Probe.run(now: @now) == {:error, :no_rate_limit_event} end)
      assert log =~ "no rate_limit_event"

      put_env!(:usage_probe_fun, fn -> raise "claude is not installed" end)
      log = capture_log(fn -> assert Probe.run(now: @now) == {:error, :probe_failed} end)
      assert log =~ "claude is not installed"

      assert Availability.usage("claude", now: @now).freshness == :unknown
    end

    test "is on the crontab by default and off when disabled" do
      put_env!(:usage_probe_cron, "*/10 * * * *")
      assert Enum.any?(Custode.Routine.crontab(), &match?({_cron, Probe, _opts}, &1))

      put_env!(:usage_probe_cron, false)
      refute Enum.any?(Custode.Routine.crontab(), &match?({_cron, Probe, _opts}, &1))
    end
  end
end
