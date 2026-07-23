defmodule Custode.DigestTest do
  # The window digest (#259 / design 004 D2): a deterministic summary over the
  # telemetry projections. Seed spend/failure/suggestion rows, then assert the
  # map shape and the markdown render.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Digest, SpendLedger}

  setup do
    feed = Path.join(System.tmp_dir!(), uid("digest-feed") <> ".jsonl")
    put_env!(:feed_path, feed)
    on_exit(fn -> File.rm(feed) end)
    :ok
  end

  test "build/1 summarizes spend, sweeps, failures, and their kinds" do
    agent = uid("dg")

    :ok =
      SpendLedger.record(agent, 0.50, "turn",
        model: "sonnet",
        usage: %{input: 1_000, output: 200}
      )

    :ok = SpendLedger.record(agent, 1.00, "turn", model: "opus")
    :ok = SpendLedger.record(agent, 0.0, "failed", stop_reason: "max_turns")
    :ok = SpendLedger.record(agent, 0.0, "failed", stop_reason: "max_turns")

    d = Digest.build(7)

    assert d.window_days == 7
    # totals are fleet-wide (shared DB), so assert on this agent's own row
    assert_in_delta d.spend.by_agent[agent].usd, 1.5, 0.001
    assert d.spend.by_agent[agent].tokens == 1_200
    assert d.spend.total_usd >= 1.5
    assert Map.has_key?(d.spend.by_model, "sonnet")
    assert Map.has_key?(d.spend.by_model, "opus")

    # two ok turns, two failed (>= : the window is fleet-wide)
    assert d.sweeps.ok >= 2
    assert d.sweeps.failed >= 2

    # failures grouped by stop_reason kind
    assert d.failures.total >= 2
    assert d.failures.by_kind["max_turns"] >= 2

    # the failure cluster surfaces as an anomaly (>= 2 failed turns)
    assert Enum.any?(d.anomalies, &(&1 =~ agent and &1 =~ "failed turns"))
  end

  test "build/1 carries standing advisor suggestions from the feed" do
    Custode.Feed.record(%{
      event: "advisor_suggestion",
      agent: "some-routine",
      advisor: "advisor-cadence",
      field: "cron",
      current: "*/30 * * * *",
      proposed: "@daily",
      confidence: "medium",
      evidence: "idle 6 of last 7 sweeps"
    })

    d = Digest.build(7)
    assert Enum.any?(d.suggestions, &(&1.advisor == "advisor-cadence" and &1.field == "cron"))
  end

  test "to_markdown renders the section headers and key numbers" do
    agent = uid("md")
    :ok = SpendLedger.record(agent, 0.25, "turn", model: "haiku")

    md = Digest.build(7) |> Digest.to_markdown()

    assert md =~ "## Fleet digest"
    assert md =~ "**Spend**"
    assert md =~ "**Sweeps**"
    assert md =~ "**Gates**"
    assert md =~ "**Failures**"
    assert md =~ "**Standing suggestions**"
    assert md =~ "**Anomalies**"
    assert md =~ agent
  end

  test "anomalies surface a rail hit from a budget_paused event (#261)" do
    agent = uid("railed")
    Custode.Feed.record(%{event: "budget_paused", agent: agent, action: "over its daily rail"})

    d = Digest.build(7)
    assert Enum.any?(d.anomalies, &(&1 =~ agent and &1 =~ "daily budget rail"))
  end

  test "build_since summarizes a precise window and labels it 'since ...'" do
    agent = uid("since")
    :ok = SpendLedger.record(agent, 0.40, "turn", model: "sonnet")

    since = DateTime.add(DateTime.utc_now(), -3600, :second)
    d = Digest.build_since(since)

    assert d.since == since
    refute Map.has_key?(d, :window_days)
    assert d.spend.by_agent[agent].usd == 0.4
    assert Digest.to_markdown(d) =~ "since "
  end

  test "to_markdown renders the empty fallbacks (quiet spend, no suggestions/anomalies)" do
    # a literal empty digest -- deterministic, unlike build/1 against a shared DB
    empty = %{
      window_days: 1,
      spend: %{total_usd: 0.0, total_tokens: 0, by_agent: %{}, by_model: %{}},
      sweeps: %{total: 0, ok: 0, failed: 0, yield_pct: 0},
      gates: %{count: 0, median_minutes: 0, recent: []},
      failures: %{total: 0, by_kind: %{}},
      suggestions: [],
      anomalies: []
    }

    md = Digest.to_markdown(empty)
    assert md =~ "(quiet)"
    assert md =~ "(none)"
  end
end
