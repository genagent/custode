defmodule Custode.AvailabilityTest do
  # Provider subscription availability as a typed policy input (#393): the
  # three freshness states, the refusal to read absence as zero, warning and
  # rejection, changing bucket layouts, and what an Attempt records.
  use ExUnit.Case, async: false

  alias Custode.Availability
  alias Custode.Availability.{Advice, Bucket, Parse, Snapshot}
  alias Custode.Availability.Collectors.{Claude, Codex}

  setup do
    Availability.attach()
    Availability.forget(:all)
    previous = Application.get_env(:custode, :availability_posture)

    on_exit(fn ->
      Availability.forget(:all)

      if previous,
        do: Application.put_env(:custode, :availability_posture, previous),
        else: Application.delete_env(:custode, :availability_posture)
    end)

    Application.delete_env(:custode, :availability_posture)
    %{now: DateTime.utc_now()}
  end

  describe "absence and staleness" do
    test "no observation reads unknown, and never as spare capacity", %{now: now} do
      advice = Availability.advise("codex", now: now)

      assert advice.freshness == :unknown
      assert advice.decision == :proceed
      assert advice.observation == nil
      assert advice.reason =~ "no availability observation"
    end

    test "a stale observation is reported as stale, not as its old numbers", %{now: now} do
      put(now: DateTime.add(now, -3600, :second), utilization: 0.1)

      advice = Availability.advise("codex", now: now)

      assert advice.freshness == :stale
      assert advice.decision == :proceed
      assert advice.reason =~ "no longer describes now"

      # the identity and age still travel, so "looked and it was stale" is
      # distinguishable from "never looked"
      assert advice.observation["age_seconds"] >= 3600
      assert advice.observation["provider"] == "codex"
    end

    test "an unreported utilization stays nil rather than becoming zero", %{now: now} do
      bucket = Parse.bucket("primary", %{"status" => "allowed"}, now)

      assert bucket.utilization == nil
      refute Bucket.over?(bucket, 0.0)
      refute Bucket.over?(bucket, 0.8)

      # and it renders as unknown, not as 0
      assert Bucket.render(bucket)["utilization"] == nil
    end
  end

  describe "warning and rejection" do
    test "rejection defers until the reported reset", %{now: now} do
      resets = DateTime.add(now, 900, :second)
      put(now: now, status: "rejected", resets_at: resets)

      advice = Availability.advise("codex", now: now)

      assert advice.decision == :defer
      assert DateTime.compare(advice.defer_until, resets) == :eq
      assert advice.reason =~ "rejecting"
      refute Advice.launchable?(advice)
    end

    test "pressure short of rejection is an operator posture, not a ban", %{now: now} do
      put(now: now, utilization: 0.93, resets_at: DateTime.add(now, 600, :second))

      # default: spend less rather than stop
      assert %{decision: :reduce} = advice = Availability.advise("codex", now: now)
      assert advice.reason =~ "cheaper"
      assert Advice.launchable?(advice)

      assert %{decision: :proceed} = Availability.advise("codex", now: now, on_warning: :ignore)

      assert %{decision: :defer} =
               deferred = Availability.advise("codex", now: now, on_warning: :defer)

      assert deferred.defer_until
    end

    test "a provider warning status counts even without a utilization number", %{now: now} do
      put(now: now, status: "allowed_warning", utilization: nil)

      assert %{decision: :reduce} = Availability.advise("codex", now: now)
    end

    test "headroom proceeds", %{now: now} do
      put(now: now, utilization: 0.2)

      assert %{decision: :proceed, freshness: :fresh} = Availability.advise("codex", now: now)
    end
  end

  describe "multiple simultaneous limits" do
    test "the worst bucket decides and the soonest reset wins", %{now: now} do
      soon = DateTime.add(now, 300, :second)
      later = DateTime.add(now, 7200, :second)

      Availability.put(%Snapshot{
        provider: "codex",
        source: "test",
        observed_at: now,
        buckets: [
          %Bucket{
            id: "a",
            status: :ok,
            utilization: 0.1,
            resets_at: later,
            window_seconds: 604_800
          },
          %Bucket{
            id: "b",
            status: :rejected,
            utilization: 1.0,
            resets_at: soon,
            window_seconds: 18_000
          }
        ]
      })

      advice = Availability.advise("codex", now: now)

      assert advice.decision == :defer
      assert DateTime.compare(advice.defer_until, soon) == :eq
      assert length(advice.observation["buckets"]) == 2
    end

    test "buckets are selected by reported shape, never by provider name", %{now: now} do
      snapshot = %Snapshot{
        provider: "codex",
        source: "test",
        observed_at: now,
        buckets: [
          %Bucket{id: "primary", status: :ok, window_seconds: 18_000, limit_type: "requests"},
          %Bucket{id: "secondary", status: :ok, window_seconds: 604_800, limit_type: "requests"}
        ]
      }

      # "the short window" without knowing that this provider calls it primary
      assert [%Bucket{id: "primary"}] =
               Snapshot.select(snapshot, max_window_seconds: 20_000)

      assert [_a, _b] = Snapshot.select(snapshot, limit_type: "requests")
      assert [] = Snapshot.select(snapshot, limit_type: "tokens")
    end
  end

  describe "the Claude collector" do
    test "records an Agent SDK rate-limit event without scraping anything", %{now: now} do
      {:ok, snapshot} =
        Claude.observe(
          %{
            "unified_status" => "allowed_warning",
            "unified_reset_at" => DateTime.to_iso8601(DateTime.add(now, 1800, :second)),
            "utilization" => 88.0,
            "some_new_field" => "kept"
          },
          now: now
        )

      assert snapshot.provider == "claude"
      assert snapshot.source == "agent_sdk_rate_limit_event"
      assert [bucket] = snapshot.buckets
      assert bucket.status == :warning
      assert_in_delta bucket.utilization, 0.88, 0.001

      # an unrecognized provider field survives as evidence
      assert snapshot.extra["some_new_field"] == "kept"

      assert %{decision: :reduce} = Availability.advise("claude", now: now)
    end

    test "handles a changed layout that reports named windows", %{now: now} do
      {:ok, snapshot} =
        Claude.observe(
          %{
            "rate_limits" => %{
              "five_hour" => %{
                "status" => "allowed",
                "used_percent" => 10,
                "window_minutes" => 300
              },
              "seven_day" => %{
                "status" => "allowed",
                "used_percent" => 55,
                "window_minutes" => 10_080
              }
            }
          },
          now: now
        )

      assert length(snapshot.buckets) == 2
      assert Enum.map(snapshot.buckets, & &1.window_seconds) |> Enum.sort() == [18_000, 604_800]
    end

    test "a malformed event is refused rather than cached" do
      assert {:error, :invalid_rate_limit_event} = Claude.observe("not an event")
      assert Availability.current("claude") == nil
    end
  end

  describe "the Codex collector" do
    test "reads quota before any Attempt starts", %{now: now} do
      payload = %{
        "rate_limits" => %{
          "primary" => %{
            "used_percent" => 42.5,
            "window_minutes" => 300,
            "resets_in_seconds" => 600,
            "status" => "allowed"
          },
          "secondary" => %{
            "used_percent" => 12,
            "window_minutes" => 10_080,
            "status" => "allowed"
          }
        },
        "plan" => "pro"
      }

      assert {:ok, snapshot} = Codex.from_payload(payload, now: now)

      assert snapshot.provider == "codex"
      assert snapshot.account_scope == "pro"
      assert [primary, secondary] = snapshot.buckets
      assert primary.id == "primary"
      assert_in_delta primary.utilization, 0.425, 0.001
      assert primary.window_seconds == 18_000
      assert DateTime.diff(primary.resets_at, now) == 600
      assert secondary.window_seconds == 604_800

      # no Attempt was involved: this is a preflight read
      assert %{decision: :proceed, freshness: :fresh} = Availability.advise("codex", now: now)
    end

    test "an unconfigured collector reports unknown instead of guessing" do
      Application.delete_env(:custode, :codex_availability_command)

      assert {:error, :collector_not_configured} = Codex.collect()
      assert %{freshness: :unknown, decision: :proceed} = Availability.advise("codex")
    end

    test "a failing collector leaves every other safeguard in charge", %{now: now} do
      failing = fn -> {:error, {:collector_failed, 1, "boom"}} end

      assert {:error, {:collector_failed, 1, "boom"}} = Codex.collect(read_fun: failing)

      # nothing cached, so availability advises proceed and changes nothing
      advice = Availability.advise("codex", now: now)
      assert advice.decision == :proceed
      assert advice.freshness == :unknown
    end
  end

  test "what an Attempt records identifies the observation, its age and its buckets", %{now: now} do
    put(now: now, utilization: 0.5)

    recorded = Availability.provenance("codex", now: now)

    assert recorded["decision"] == "proceed"
    assert recorded["freshness"] == "fresh"
    assert recorded["policy_version"] == "availability:v1"
    assert recorded["reason"] != ""
    assert recorded["observation"]["provider"] == "codex"
    assert recorded["observation"]["source"] == "test"
    assert is_integer(recorded["observation"]["age_seconds"])
    assert [%{"id" => "primary"}] = recorded["observation"]["buckets"]
  end

  test "an unchecked provider still records that nothing was observed" do
    recorded = Availability.provenance("codex")

    assert recorded["freshness"] == "unknown"
    assert recorded["observation"] == nil
    assert recorded["policy_version"] == "availability:v1"
  end

  test "a newer observation replaces an older one", %{now: now} do
    put(now: DateTime.add(now, -60, :second), utilization: 0.1)
    put(now: now, utilization: 0.95)

    assert %{decision: :reduce} = Availability.advise("codex", now: now)
  end

  defp put(options) do
    now = Keyword.fetch!(options, :now)

    Availability.put(%Snapshot{
      provider: Keyword.get(options, :provider, "codex"),
      source: "test",
      observed_at: now,
      buckets: [
        %Bucket{
          id: "primary",
          status: Parse.status(Keyword.get(options, :status, "allowed")),
          window_seconds: 18_000,
          limit_type: "requests",
          utilization: Keyword.get(options, :utilization),
          resets_at: Keyword.get(options, :resets_at)
        }
      ]
    })
  end
end
