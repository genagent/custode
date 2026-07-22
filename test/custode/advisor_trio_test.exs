defmodule Custode.AdvisorTrioTest do
  # The model and budget advisors plus cadence v2 (#111/#124/#125): seeded
  # ledger/feed data in, suggestions with evidence out. All deterministic.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Advisors.{Budget, Cadence, Model}

  setup do
    path = Path.join(System.tmp_dir!(), uid("trio-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp seed_turns(agent, n),
    do: for(_i <- 1..n, do: Custode.Feed.record(%{event: "turn", agent: agent, summary: "s"}))

  defp seed_yields(agent, n),
    do:
      for(_i <- 1..n, do: Custode.Feed.record(%{event: "repo_verb", agent: agent, summary: "ok"}))

  test "model: an opus sweeper yielding like the sonnet fleet gets the downgrade suggestion" do
    workspace = tmp_workspace!()
    heavy = uid("heavy")
    peer = uid("peer")

    put_env!(:routines, [
      %{id: heavy, cron: "@daily", workspace: workspace, prompt: "s", model: "opus"},
      %{id: peer, cron: "@daily", workspace: workspace, prompt: "s", model: "sonnet"}
    ])

    # peer: 20 sweeps, 10 yields (50%); heavy: 20 opus sweeps, 4 yields (20%)
    seed_turns(peer, 20)
    seed_yields(peer, 10)
    seed_turns(heavy, 20)
    seed_yields(heavy, 4)

    suggestions = Model.observe() |> Model.suggest()
    assert [s] = Enum.filter(suggestions, &(&1.routine_id == heavy))
    assert s.proposed == "sonnet"
    assert s.evidence =~ "approved turns keep opus"
  end

  test "model: an opus sweeper OUT-yielding the fleet is left alone" do
    workspace = tmp_workspace!()
    earner = uid("earner")
    peer = uid("peer")

    put_env!(:routines, [
      %{id: earner, cron: "@daily", workspace: workspace, prompt: "s", model: "opus"},
      %{id: peer, cron: "@daily", workspace: workspace, prompt: "s", model: "sonnet"}
    ])

    seed_turns(peer, 20)
    seed_yields(peer, 4)
    seed_turns(earner, 20)
    seed_yields(earner, 15)

    assert Model.observe() |> Model.suggest() |> Enum.filter(&(&1.routine_id == earner)) == []
  end

  test "budget: a slack rail suggests lowering; a binding-but-productive one suggests raising" do
    workspace = tmp_workspace!()
    slack = uid("slack")
    bound = uid("bound")

    put_env!(:routines, [
      %{id: slack, cron: "@daily", workspace: workspace, prompt: "s", daily_budget_usd: 50.0},
      %{id: bound, cron: "@daily", workspace: workspace, prompt: "s", daily_budget_usd: 5.0}
    ])

    # slack: three ACTIVE DAYS peaking at $4 against a $50 rail -- backdated
    # rows, since spend_series buckets per day
    for {cost, days_ago} <- [{3.0, 1}, {4.0, 2}, {2.0, 3}] do
      Custode.Repo.insert!(%Custode.SpendLedger.Entry{
        agent_id: slack,
        cost_usd: cost,
        outcome: "turn",
        inserted_at: DateTime.add(DateTime.utc_now(), -days_ago * 24 * 3600, :second)
      })
    end

    # bound: paused on its rail this week, yet its work landed
    Custode.Feed.record(%{event: "budget_paused", agent: bound, summary: "rail"})
    Custode.Feed.record(%{event: "repo_verb", agent: bound, summary: "merged"})

    suggestions = Budget.observe() |> Budget.suggest()

    assert [lower] = Enum.filter(suggestions, &(&1.routine_id == slack))
    assert lower.proposed < 50.0
    assert lower.evidence =~ "unused headroom"

    assert [raise_s] = Enum.filter(suggestions, &(&1.routine_id == bound))
    assert raise_s.proposed > 5.0
    assert raise_s.confidence == :high
  end

  test "cadence v2: a yielding daily routine with real backlog gets a windowed ramp-up" do
    workspace = tmp_workspace!()
    busy = uid("busy")

    put_env!(:routines, [
      %{id: busy, cron: "@daily", workspace: workspace, prompt: "s", repo: "o/busyrepo"}
    ])

    seed_turns(busy, 8)
    seed_yields(busy, 6)

    # the repo read verb is unreachable in test (no served repo): backlog
    # reads 0 and NO ramp-up fires -- the guarded-degradation path
    assert Cadence.observe() |> Cadence.suggest() |> Enum.filter(&(&1.routine_id == busy)) == []
  end
end
