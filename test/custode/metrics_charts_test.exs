defmodule Custode.MetricsChartsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Metrics, Repo}
  alias Custode.SpendLedger.Entry
  alias Custode.Workflow.Run

  test "saved runs merge by workflow before ranking, including old and custom run IDs" do
    with_spend_fixture(fn ->
      workflow = uid("saved-workflow")
      generated = Ecto.UUID.generate()
      custom = uid("operator chosen:run/with-hyphens")
      saved_run(generated, workflow)
      saved_run(custom, workflow)
      spend(Run.spend_agent_id(generated), 3.0, 30, -1)
      spend(Run.spend_agent_id(custom), 3.0, 70)

      for value <- 1..5, do: spend(uid("agent"), value * 1.0, value)

      chart = Metrics.daily_charts(3).usd
      key = {:workflow, workflow}
      assert %{kind: :workflow, total: 6.0} = series(chart, key)
      assert hd(chart.series).key == key
      assert day(chart, -1).values[key] == 3.0
      assert day(chart, 0).values[key] == 3.0
      assert day(chart, -2) == %{date: date(-2), total: 0, values: %{}}
      assert series(chart, :other).total == 1.0
      assert chart.total == 21.0
      refute series(chart, {:agent, Run.spend_agent_id(generated)})
      refute series(chart, {:agent, Run.spend_agent_id(custom)})

      raw = Metrics.daily_by_agent(3)
      assert raw[date(-1)][Run.spend_agent_id(generated)].usd == 3.0
      assert raw[date(0)][Run.spend_agent_id(custom)].tokens == 70
      assert Metrics.spend_series(Run.spend_agent_id(custom), 3) == [0.0, 0.0, 3.0]
      assert Metrics.spend_series_by_agent(3)[Run.spend_agent_id(custom)] == [0.0, 0.0, 3.0]
    end)
  end

  test "USD and tokens rank independently and conserve every day and the whole window" do
    with_spend_fixture(fn ->
      agents = for index <- 1..8, do: {uid("rank-#{index}"), index}

      for {agent, index} <- agents do
        spend(agent, (11 - index) / 2, index, -1)
        spend(agent, (11 - index) * 1.0, index * 10)
      end

      charts = Metrics.daily_charts(3)
      usd_keys = agents |> Enum.take(5) |> Enum.map(fn {id, _} -> {:agent, id} end)
      token_keys = agents |> Enum.drop(3) |> Enum.map(fn {id, _} -> {:agent, id} end)

      assert named_keys(charts.usd) == MapSet.new(usd_keys)
      assert named_keys(charts.tokens) == MapSet.new(token_keys)
      assert hd(charts.usd.series).key == :other
      assert series(charts.usd, :other).total == 18.0
      assert series(charts.tokens, :other).total == 66
      assert charts.usd.max == 52.0
      assert charts.tokens.max == 360
      assert charts.usd.total == 78.0
      assert charts.tokens.total == 396

      for {metric, chart} <- charts do
        assert chart.metric == metric
        assert chart.today == date(0)
        assert Enum.map(chart.days, & &1.date) == [date(-2), date(-1), date(0)]
        assert length(chart.series) == 6
        assert chart.series == Enum.sort_by(chart.series, &{-&1.total, &1.key})
        assert chart.total == Enum.sum(Enum.map(chart.series, & &1.total))
        assert chart.total == Enum.sum(Enum.map(chart.days, & &1.total))

        for day <- chart.days do
          assert day.total == Enum.sum(Map.values(day.values))

          assert MapSet.subset?(
                   MapSet.new(Map.keys(day.values)),
                   MapSet.new(chart.series, & &1.key)
                 )
        end
      end

      assert day(charts.usd, -1).total == 26.0
      assert day(charts.usd, 0).total == 52.0
      assert day(charts.tokens, -1).total == 36
      assert day(charts.tokens, 0).total == 360
    end)
  end

  test "unmatched workflow-looking IDs stay agents and ownership is exact" do
    with_spend_fixture(fn ->
      run_id = uid("custom-run")
      workflow = uid("owner")
      saved_run(run_id, workflow)
      exact = Run.spend_agent_id(run_id)
      unmatched = exact <> "-unmatched"
      spend(exact, 2.0, 20)
      spend(unmatched, 4.0, 40)
      spend(uid("outside-window"), 1_000.0, 10_000, -3)
      saved_run(uid("without-spend"), uid("unused-workflow"))

      chart = Metrics.daily_charts(3).usd
      assert series(chart, {:workflow, workflow}).total == 2.0
      assert series(chart, {:agent, unmatched}).label == "Agent: #{unmatched}"
      assert length(chart.series) == 2
      assert chart.total == 6.0
    end)
  end

  test "typed identities distinguish shared names and the Other aggregate" do
    with_spend_fixture(fn ->
      shared = uid("shared-name")
      shared_run = uid("shared-run")
      other_run = uid("other-run")
      saved_run(shared_run, shared)
      saved_run(other_run, "Other")
      spend(shared, 10.0, 100)
      spend(Run.spend_agent_id(shared_run), 9.0, 90)
      spend(Run.spend_agent_id(other_run), 8.0, 80)
      for value <- 4..7, do: spend(uid("remaining"), value * 1.0, value * 10)

      chart = Metrics.daily_charts(1).usd
      assert series(chart, {:agent, shared}).label == "Agent: #{shared}"
      assert series(chart, {:workflow, shared}).label == "Workflow: #{shared}"
      assert series(chart, {:workflow, "Other"}).label == "Workflow: Other"
      assert series(chart, :other) == %{key: :other, kind: :other, label: "Other", total: 9.0}
      assert chart.total == 49.0
      assert length(Enum.uniq_by(chart.series, & &1.key)) == 6
      assert length(Enum.uniq_by(chart.series, & &1.label)) == 6
    end)
  end

  test "equal totals use stable identity ordering for selection and display" do
    with_spend_fixture(fn ->
      prefix = uid("tie")
      agents = for suffix <- ~w(a b c d e f), do: prefix <> "-" <> suffix
      for agent <- Enum.reverse(agents), do: spend(agent, 1.0, 1)

      first = Metrics.daily_charts(1)
      assert first == Metrics.daily_charts(1)
      expected = agents |> Enum.take(5) |> MapSet.new(&{:agent, &1})

      for chart <- Map.values(first) do
        assert named_keys(chart) == expected
        assert chart.series == Enum.sort_by(chart.series, &{-&1.total, &1.key})
        assert series(chart, :other).total == 1
        assert chart.total == 6
      end
    end)
  end

  test "zero charts keep padded days and a token-only contributor does not enter USD" do
    with_spend_fixture(fn ->
      for chart <- Metrics.daily_charts(3) |> Map.values() do
        assert chart.series == []
        assert chart.max == 0
        assert chart.total == 0
        assert length(chart.days) == 3
        assert Enum.all?(chart.days, &(&1.total == 0 and &1.values == %{}))
      end

      agent = uid("token-only")
      spend(agent, 0.0, 120, -1)
      charts = Metrics.daily_charts(3)
      assert charts.usd.series == []
      assert charts.usd.max == 0
      assert charts.tokens.max == 120
      assert charts.tokens.total == 120
      assert series(charts.tokens, {:agent, agent}).total == 120
      assert day(charts.tokens, 0) == %{date: date(0), total: 0, values: %{}}
    end)
  end

  # These whole-fleet read models need exact fixture totals. Keep both the
  # temporary clearing and all fixture rows inside the caller's transaction.
  defp with_spend_fixture(fun) do
    assert {:error, :fixture_complete} =
             Repo.transaction(fn ->
               Repo.delete_all(Entry)
               fun.()
               Repo.rollback(:fixture_complete)
             end)
  end

  defp saved_run(run_id, workflow) do
    Repo.insert!(%Run.Row{
      run_id: run_id,
      workflow: workflow,
      repo: "test/metrics",
      status: "complete",
      context: "{}",
      notes: "[]",
      started_at: timestamp(-90),
      finished_at: timestamp(-89)
    })
  end

  defp spend(agent, usd, tokens, offset \\ 0) do
    Repo.insert!(%Entry{
      agent_id: agent,
      cost_usd: usd,
      outcome: "turn",
      input_tokens: tokens,
      attribution_status: "legacy_unattributed",
      inserted_at: timestamp(offset)
    })
  end

  defp timestamp(offset),
    do: Date.utc_today() |> Date.add(offset) |> DateTime.new!(~T[12:00:00.000000], "Etc/UTC")

  defp date(offset), do: Date.utc_today() |> Date.add(offset) |> Date.to_iso8601()
  defp day(chart, offset), do: Enum.find(chart.days, &(&1.date == date(offset)))
  defp series(chart, key), do: Enum.find(chart.series, &(&1.key == key))

  defp named_keys(chart),
    do: chart.series |> Enum.reject(&(&1.kind == :other)) |> MapSet.new(& &1.key)
end
