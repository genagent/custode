defmodule Custode.AdvisorTest do
  # The advisor behaviour + the cadence advisor (#125 slice 1). The behaviour
  # is exercised through a scripted advisor; Cadence through seeded feed rows
  # and a scoped roster.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Advisors.Cadence

  setup do
    path = Path.join(System.tmp_dir!(), uid("advisor-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defmodule Scripted do
    use Custode.Advisor

    @impl Custode.Advisor
    def observe, do: Application.get_env(:custode, :scripted_observations, [])

    @impl Custode.Advisor
    def suggest(observations), do: observations

    @impl Custode.Advisor
    def key(suggestion), do: "scripted:#{suggestion.routine_id}:#{suggestion.proposed}"
  end

  defp suggestion(routine_id, proposed) do
    %{
      routine_id: routine_id,
      field: :cron,
      current: "*/10 * * * *",
      proposed: proposed,
      confidence: :medium,
      evidence: "scripted"
    }
  end

  test "fresh suggestions land in the feed; standing ones do not re-nag; drops age out" do
    id = uid("adv")
    Application.put_env(:custode, :scripted_observations, [suggestion(id, "@daily")])

    :ok = Custode.Advisor.run(Scripted)

    entries = Custode.Feed.for_agent(id)
    assert [%{"event" => "advisor_suggestion"} = entry] = entries
    assert entry["proposed"] == "@daily"
    assert entry["summary"] =~ "cron */10 * * * * -> @daily"

    # the same suggestion again: cooled down, no second feed entry
    :ok = Custode.Advisor.run(Scripted)
    assert length(Custode.Feed.for_agent(id)) == 1

    # the suggestion stops being made, then returns: it may honestly re-fire
    Application.put_env(:custode, :scripted_observations, [])
    :ok = Custode.Advisor.run(Scripted)
    Application.put_env(:custode, :scripted_observations, [suggestion(id, "@daily")])
    :ok = Custode.Advisor.run(Scripted)
    assert length(Custode.Feed.for_agent(id)) == 2
  after
    Application.delete_env(:custode, :scripted_observations)
  end

  test "cadence suggests @daily for a busy-but-idle sub-daily routine, with evidence" do
    workspace = tmp_workspace!()
    noisy = uid("noisy")
    earner = uid("earner")

    put_env!(:routines, [
      %{id: noisy, cron: "*/10 * * * *", workspace: workspace, prompt: "sweep"},
      %{id: earner, cron: "*/10 * * * *", workspace: workspace, prompt: "sweep"}
    ])

    # noisy: 25 sweeps, 1 gate -- 4% utilization. earner: 25 sweeps, 20 verbs.
    for _i <- 1..25, do: Custode.Feed.record(%{event: "turn", agent: noisy, summary: "nothing"})
    Custode.Feed.record(%{event: "needs_approval", agent: noisy, action: "one thing"})
    for _i <- 1..25, do: Custode.Feed.record(%{event: "turn", agent: earner, summary: "work"})
    for _i <- 1..20, do: Custode.Feed.record(%{event: "repo_verb", agent: earner, summary: "ok"})

    suggestions = Cadence.observe() |> Cadence.suggest()

    assert [only] = suggestions
    assert only.routine_id == noisy
    assert only.proposed == "@daily"
    assert only.evidence =~ "1 of 25 sweeps"
    # under 60 sweeps of evidence stays medium confidence
    assert only.confidence == :medium
  end

  test "cadence stays quiet without enough evidence or for daily crons" do
    workspace = tmp_workspace!()
    sparse = uid("sparse")
    daily = uid("daily")

    put_env!(:routines, [
      %{id: sparse, cron: "*/30 * * * *", workspace: workspace, prompt: "sweep"},
      %{id: daily, cron: "@daily", workspace: workspace, prompt: "sweep"}
    ])

    # sparse: only 5 sweeps -- below the evidence floor. daily: shorthand cron.
    for _i <- 1..5, do: Custode.Feed.record(%{event: "turn", agent: sparse, summary: "nothing"})
    for _i <- 1..30, do: Custode.Feed.record(%{event: "turn", agent: daily, summary: "nothing"})

    ids =
      Cadence.observe()
      |> Cadence.suggest()
      |> Enum.map(& &1.routine_id)

    refute sparse in ids
    refute daily in ids
  end
end
