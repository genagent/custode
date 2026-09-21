defmodule Custode.Attention.Fleet do
  @moduledoc """
  The impure half of the attention resolver (#296): reads the fleet's state
  and builds the plain view maps `Custode.Attention.resolve/2` consumes.

  Kept separate and deliberately thin. Everything that touches the registry,
  the database or the clock lives here, so the ranking itself stays a pure
  function that a test can drive with hand-written facts. If this module grows
  a decision, the decision is in the wrong module.

  No new data sources: every read here is one the fleet page already performs
  in `CustodeWeb.FleetLive.refresh/1`. Gates are the one improvement, fetched
  in a single grouped query rather than one per agent.

  Every read is also non-blocking, including the one that consults GitHub:
  promoting a red check to `:needs_you` verifies it first, and
  `Custode.Attention.Verify` answers that from its own cache while the live
  re-check runs behind it (#317).
  """

  alias Custode.Asks
  alias Custode.Attention
  alias Custode.Attention.Verify
  alias Custode.Disowned
  alias Custode.Gates
  alias Custode.Routine
  alias Custode.RunClock
  alias Custode.Sensor.Health
  alias Custode.Signal
  alias Custode.SpendLedger
  alias Custode.TurnFailure
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run
  alias ObanClaude.Agent

  @doc """
  Every agent's view: the configured routines, plus any live agent not in the
  roster (sub-agents and one-shots, which have no cron and resolve to
  `:quiet`).
  """
  @spec views() :: [map()]
  def views do
    routines = Routine.all()
    running = Map.new(Agent.list())

    sources = %{
      gates: Gates.open_by_agent(),
      asks: Asks.open_by_agent(),
      in_flight: Map.new(RunClock.running()),
      spend: SpendLedger.today_by_agent(),
      disowned: Disowned.by_repo(),
      sensor_failures: sensor_failures(),
      turn_failures: turn_failures(),
      next_beats: Custode.NextBeat.pending(),
      routines: Map.new(routines, &{&1.id, &1})
    }

    # Agents with an OPEN ASK are included even when they are neither in the
    # roster nor in the registry (#301). An ask outlives the agent that filed
    # it: a routine removed from the roster mid-question would otherwise leave
    # a row nobody can see and nobody can answer, which is a leak rather than
    # a tidy-up. Something is owed, so something is shown.
    #
    # The owner of a failing sensor is included on the same reasoning (#444).
    # A sensor's `notify` is not checked against the roster, and removing a
    # routine leaves its sensors in place (`Config.WriteBack.remove_routine/1`),
    # so a sensor can be failing for an agent that is in neither list.
    ids =
      Enum.uniq(
        Enum.map(routines, & &1.id) ++
          Map.keys(running) ++ Map.keys(sources.asks) ++ Map.keys(sources.sensor_failures)
      )

    for id <- ids, do: view(id, Map.get(running, id, :offline), sources)
  end

  @doc """
  Every agent's signal, ranked. The one call a surface needs.

      Custode.Attention.Fleet.signals()
      |> Enum.filter(&Custode.Signal.needs_you?/1)
  """
  @spec signals() :: [Signal.t()]
  def signals do
    per_agent = Enum.map(views(), &Attention.resolve(&1, context()))

    # The host signal has no view to come from, so it joins here and every
    # reader of this list (chip, inbox, CLI, MCP) gets it unchanged (#443).
    #
    # The workflow signals join the same way (#447): a launch proposal and a
    # parked run have no agent behind them either.
    [Attention.host(Custode.Host.facts()) | Attention.workflows(workflow_facts()) ++ per_agent]
    |> Enum.reject(&is_nil/1)
    |> Attention.rank()
  end

  @doc """
  The facts `Custode.Attention.workflows/1` resolves (#447): the launch
  proposals still standing and the runs parked on their rail.

  Both stores already exist and both already answer "what is waiting"; this
  only reshapes them. Public so a test can assert on the gathering without
  going through the ranked list.
  """
  @spec workflow_facts() :: %{launches: [map()], paused_runs: [map()]}
  def workflow_facts do
    %{
      launches: Enum.map(Launch.pending(), &launch_fact/1),
      paused_runs: paused_runs()
    }
  end

  defp launch_fact(entry) do
    %{
      id: entry["proposal"],
      workflow: entry["workflow"],
      repo: entry["repo"],
      summary: entry["summary"],
      why: entry["why"],
      proposed_at: parse_at(entry["at"])
    }
  end

  # The run row records that it is parked and why, not when: the pause is a
  # status change on a row with no timestamp for it. The `workflow_budget_paused`
  # feed entry is the record of when, and it is only read when a run is
  # actually parked, which is rare.
  defp paused_runs do
    case Run.list(status: "budget_paused") do
      [] ->
        []

      runs ->
        paused_at =
          "workflow_budget_paused"
          |> Custode.Feed.recent_by_event(limit: 50)
          |> Enum.reverse()
          |> Map.new(&{&1["run"], parse_at(&1["at"])})

        for run <- runs do
          %{
            run_id: run.run_id,
            workflow: run.workflow,
            repo: run.repo,
            # the pause note says what was spent AND which nodes did not run;
            # `error` is the same sentence without the second half
            reason: List.last(run.notes) || run.error,
            paused_at: Map.get(paused_at, run.run_id)
          }
        end
    end
  end

  defp parse_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> at
      {:error, _reason} -> nil
    end
  end

  defp parse_at(_absent), do: nil

  @doc """
  Ranked signals bucketed by group, in page order and without empty groups.
  """
  @spec by_group() :: [{Signal.group(), [Signal.t()]}]
  def by_group, do: signals() |> Attention.by_group()

  @doc """
  Signals keyed by agent id, for a caller that already holds its own per-agent
  data and only wants the resolved signal to merge into it.

  Ranking is a property of a LIST, so this returns the map unranked. Rank the
  values with `Custode.Attention.rank/1` when order matters.
  """
  @spec signals_by_id() :: %{String.t() => Signal.t()}
  def signals_by_id do
    context = context()

    Map.new(views(), fn view -> {view.id, Attention.resolve(view, context)} end)
  end

  # Everything the resolver must not read for itself: the clock, and the one
  # piece of configuration a resolver decision depends on (#444).
  defp context do
    %{now: DateTime.utc_now(), sensor_failure_threshold: Health.threshold()}
  end

  defp view(id, status, sources) do
    routine = Map.get(sources.routines, id)

    %{
      id: id,
      state: Custode.state_of(status),
      detail: status_detail(status),
      gate: sources.gates |> Map.get(id, []) |> List.first() |> gate_view(),
      # OLDEST open ask, not newest: staleness is what should surface, and an
      # agent with three open questions is owed the first one first.
      ask: sources.asks |> Map.get(id, []) |> List.last() |> ask_view(),
      failing_prs: failing_prs(routine, sources.disowned),
      sensor_failures: Map.get(sources.sensor_failures, id, []),
      turn_failure: Map.get(sources.turn_failures, id),
      default_branch: default_branch(routine),
      spend_today: Map.get(sources.spend, id, 0.0),
      budget: routine && routine.daily_budget_usd,
      running_since: Map.get(sources.in_flight, id),
      cron: routine && routine.cron,
      next_beat_at: routine && next_beat_at(routine, sources.next_beats)
    }
  end

  # Failure streaks of the CONFIGURED sensors, grouped by the agent each one
  # notifies (#444). The configured list is the join's left side on purpose: a
  # sensor removed from config leaves its `health` memory behind, and a streak
  # for a sensor that no longer runs can never be cleared by a success.
  #
  # Every streak is passed through, however short. Whether one is long enough
  # to raise a signal is the resolver's decision, not the gatherer's.
  defp sensor_failures do
    health = Health.failing()

    if health == %{} do
      %{}
    else
      for sensor <- Routine.sensors(), streak = Map.get(health, sensor.id), reduce: %{} do
        by_agent ->
          fact = Map.put(streak, :id, sensor.id)
          Map.update(by_agent, sensor.notify, [fact], &[fact | &1])
      end
    end
  end

  # Agents whose most recent turn failed for a reason the next beat cannot fix
  # (#527), keyed by agent. One read of the recent failures finds the
  # candidates, and only a candidate's own feed is read for the streak, so a
  # healthy fleet pays one query.
  #
  # Only entries carrying a `category` count as outcomes. `turn_failed` is
  # also recorded for things that are not turns (a drain timeout, an
  # undeliverable orphan notice), and those neither start nor break a streak.
  defp turn_failures do
    "turn_failed"
    |> Custode.Feed.recent_by_event(limit: 100)
    |> Enum.filter(&TurnFailure.from_entry/1)
    |> Enum.uniq_by(& &1["agent"])
    |> Enum.reject(&TurnFailure.retryable?(TurnFailure.from_entry(&1)))
    |> Enum.flat_map(&turn_failure(&1["agent"]))
    |> Map.new()
  end

  defp turn_failure(agent_id) do
    agent_id
    |> TurnFailure.streak()
    |> turn_failure_fact(agent_id)
  end

  # A success since the failure leaves nothing to take, so nothing is owed.
  defp turn_failure_fact([], _agent_id), do: []

  defp turn_failure_fact([latest | _older] = failed, agent_id) do
    category = TurnFailure.from_entry(latest)
    streak = Enum.take_while(failed, &(TurnFailure.from_entry(&1) == category))

    [
      {agent_id,
       %{
         category: category,
         failures: length(streak),
         detail: latest["detail"],
         since: streak |> List.last() |> Map.get("at") |> parse_at()
       }}
    ]
  end

  # The gen_statem knows it is gated; only the durable row knows since when,
  # which is exactly the field the ranking needs.
  defp gate_view(nil), do: nil

  defp gate_view(gate) do
    %{
      kind: gate.kind,
      class: gate.class,
      risk: gate.risk,
      risk_paths: risk_paths(gate.risk_paths),
      detail: gate.detail,
      action_id: gate.action_id,
      opened_at: gate.inserted_at
    }
  end

  # An agent's own request (#526) is when it next runs; the cron only says so
  # when there is none.
  defp next_beat_at(routine, next_beats) do
    Map.get(next_beats, routine.id) || Custode.Scheduler.next_beat_at(routine.cron)
  end

  defp risk_paths(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, paths} when is_list(paths) -> paths
      _other -> []
    end
  end

  defp risk_paths(_none), do: []

  defp ask_view(nil), do: nil

  defp ask_view(ask) do
    %{
      id: ask.id,
      question: ask.question,
      detail: ask.detail,
      replies: Asks.replies(ask),
      asked_at: ask.inserted_at
    }
  end

  # The live status payload for a gated agent: the question text, or the
  # pending action's description.
  defp status_detail({:waiting_for_user, question}) when is_binary(question), do: question
  defp status_detail({:awaiting_permission, %{description: description}}), do: description
  defp status_detail(_status), do: nil

  # Reads the cached overview only, exactly as the fleet page does: the cache
  # refreshes on its own cadence and broadcasts, so resolving attention costs
  # no GitHub calls.
  #
  # Marks each failing PR as disowned or not HERE (#313), so the resolver only
  # partitions a list of facts. Deciding it in both places would be one
  # judgment made twice, which is how two surfaces start disagreeing.
  defp failing_prs(%{repo: repo}, disowned) when is_binary(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} ->
        numbers = Map.get(disowned, repo, MapSet.new())

        overview.open_prs.items
        |> Enum.filter(&(&1[:checks] in ["FAILURE", "ERROR"]))
        |> Enum.map(&pr_fact(repo, &1.number, MapSet.member?(numbers, &1.number)))
        |> Enum.reject(&is_nil/1)

      :loading ->
        []

      # A repo GitHub will not serve is a repo with no data (#485): no red
      # check can be claimed from an overview nobody could read.
      {:error, _reason} ->
        []
    end
  end

  defp failing_prs(_routine, _disowned), do: []

  # A red check the agent still owns takes the cached signal as it stands: it
  # resolves to `:red_check` in `:watching`, where being a cache-cycle behind
  # costs a row nobody was going to act on this minute.
  defp pr_fact(_repo, number, false = _disowned?), do: %{number: number, disowned?: false}

  # A disowned one is a promotion to `:needs_you`, so it asks GitHub first
  # (#317). `:cleared` drops the PR entirely rather than demoting it: the live
  # checks say nothing is failing, so there is no signal left to file
  # anywhere, and the cache catches up on its own cadence. `:unverified` means
  # the answer is still in flight -- fall back to the cached tier, which is
  # the same row minus the escalation.
  defp pr_fact(repo, number, true = _disowned?) do
    case Verify.verdict(repo, number) do
      :red -> %{number: number, disowned?: true}
      :cleared -> nil
      :unverified -> %{number: number, disowned?: false}
    end
  end

  # Same cached overview, one more field (#310). An agent with no repository
  # has no branch to be red, which is why this is nil rather than green.
  defp default_branch(%{repo: repo}) when is_binary(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} -> Map.get(overview, :default_branch)
      :loading -> nil
      # unreadable is not red (#485), the same as not fetched yet
      {:error, _reason} -> nil
    end
  end

  defp default_branch(_routine), do: nil
end
