defmodule Custode.MetricsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Metrics

  @endpoint CustodeWeb.Endpoint

  test "daily_by_agent covers the whole window and sums usd + throughput tokens" do
    agent = uid("metric")

    :ok =
      Custode.SpendLedger.record(agent, 0.5, "turn",
        usage: %{input: 1_000, output: 200, cache_creation: 100, cache_read: 9_999}
      )

    :ok = Custode.SpendLedger.record(agent, 0.25, "turn")

    daily = Metrics.daily_by_agent(3)
    assert map_size(daily) == 3

    today = Date.utc_today() |> Date.to_iso8601()
    assert %{usd: usd, tokens: 1_300} = daily[today][agent]
    assert_in_delta usd, 0.75, 0.0001
  end

  test "turns_by_day splits ok from failed" do
    agent = uid("outcomes")
    :ok = Custode.SpendLedger.record(agent, 0.1, "turn")
    :ok = Custode.SpendLedger.record(agent, 0.0, "failed")

    today = Date.utc_today() |> Date.to_iso8601()
    counts = Metrics.turns_by_day(2)[today]
    assert counts.ok >= 1
    assert counts.failed >= 1
  end

  test "gate_latencies measures open -> resolved in minutes with a median" do
    id = start_stub_agent!()
    import ObanClaude.Testing
    alias ObanClaude.Agent

    :processing = Agent.submit_prompt(id, "go")

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => "act now"})
      )

    {:ok, {:awaiting_permission, action}} = Agent.await(id, :awaiting_permission, 1_000)
    :rejected = Agent.reject_action(id, action.id, "test")
    {:ok, :idle} = Agent.await(id, :idle, 1_000)

    {gates, median} = Metrics.gate_latencies()
    assert gate = Enum.find(gates, &(&1.agent == id))
    assert gate.minutes >= 0
    assert gate.detail =~ "act now"
    assert is_integer(median)
  end

  test "spend_series is oldest-first and window-padded (sparkline shape)" do
    agent = uid("series")
    :ok = Custode.SpendLedger.record(agent, 2.0, "turn")

    series = Metrics.spend_series(agent, 7)
    assert length(series) == 7
    assert List.last(series) == 2.0
    assert Enum.take(series, 6) == [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]

    assert Metrics.spend_series_by_agent(7)[agent] == series
  end

  test "by_model groups cost/tokens/outcomes per model (#111 display)" do
    agent = uid("bym")
    # by_model/1 aggregates fleet-wide (that IS the display), so real model
    # names collide with rows other tests push through the ledger; unique
    # names keep this test about grouping, not suite ordering
    big = uid("model-big")
    small = uid("model-small")

    :ok =
      Custode.SpendLedger.record(agent, 1.0, "turn",
        model: big,
        usage: %{input: 100, output: 50}
      )

    :ok = Custode.SpendLedger.record(agent, 0.1, "failed", model: small)
    :ok = Custode.SpendLedger.record(agent, 0.2, "turn")

    by_model = Custode.Metrics.by_model(2)
    assert %{usd: 1.0, tokens: 150, turns: 1, failed: 0} = by_model[big]
    assert %{turns: 1, failed: 1} = by_model[small]
    assert by_model["(unrecorded)"].turns >= 1
  end

  test "the metrics page renders all four sections" do
    agent = uid("page")
    :ok = Custode.SpendLedger.record(agent, 1.0, "turn", usage: %{input: 500, output: 100})

    {:ok, view, _html} = live(build_conn(), "/metrics")
    assert has_element?(view, "h2", "Spend per day")
    assert has_element?(view, "h2", "Tokens per day")
    assert has_element?(view, "h2", "Turns per day")
    assert has_element?(view, "h2", "gate latency")
    assert has_element?(view, "h2", "by model")
    assert has_element?(view, "#daily-spend")
    assert has_element?(view, "#daily-tokens")
    assert has_element?(view, "#daily-turns")
    # the fleet digest panel (the design/004 D2 human reader)
    assert has_element?(view, "#metrics-digest-panel[data-digest-panel]", "Fleet digest")
    refute has_element?(view, "#metrics-digest-panel > pre")
    refute has_element?(view, "#metrics-digest-panel details[open]")
  end
end
