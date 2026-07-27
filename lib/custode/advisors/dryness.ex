defmodule Custode.Advisors.Dryness do
  @moduledoc """
  The dryness advisor (design/005 slice 4, #274): the fleet asks for a deep
  dig when the board it works has run dry.

  This is the second entry point to a workflow run. The button (slice 3) is a
  human noticing; this is the fleet noticing. design/005 is explicit that
  there is no second PATH -- both arrive at `Custode.Workflow.Launch.propose/3`
  and nothing is enqueued until the operator approves on /workflows. What this
  module decides is only WHEN to raise the gate, and its `:why` says what it
  saw, so a proposal read hours later still explains itself.

  ## The flywheel

  Routines drain the board; a workflow refills it; the cadence advisor notices
  the utilization that follows and suggests ramping; the spend rails cap the
  loop. The deep dig becomes a thing the fleet ASKS for when it runs out of
  work, instead of something the operator has to remember to launch.

  ## Why it is not a `Custode.Advisor`

  It rides the same lane -- a plain worker on the `:sensors` queue, riding the
  static crontab, deterministic and zero-token -- and it is toggled from the
  same `[advisors]` config. But an advisor's output object is a config
  SUGGESTION (`field`, `current`, `proposed`) addressed to the operator, and
  this produces a launch gate. Wearing the behaviour would mean emitting a
  suggestion nobody can apply next to a gate that is the real proposal.

  ## When it fires

  Both halves, per repo, or nothing:

    * DRY: the board's `workable` count is at or below 2 and the repo could
      actually be READ -- an unreadable repo is not a dry one, which is why
      `Custode.Backlog.read/1` distinguishes the two.
    * IDLE: the repo's routines swept at least 5 times in the last 7 days
      and produced no gate and no verb between them. A repo whose routines
      still yield does not need a refill, and one that has not swept at all
      has no evidence either way.

  Aggregated per REPO rather than per routine, because workflows are
  repo-scoped: two routines on one repo where one still yields is a repo with
  work left, not two independent signals.

  ## Why it does not re-nag

  Three suppressions, all read off state that already exists:

    * a launch gate for this workflow and repo is already standing
      (`Launch.standing_for/1`) -- the operator has the decision already;
    * one was rejected inside the proposal window
      (`Launch.recently_rejected?/2`) -- the rejection in the feed IS the
      cooldown, so there is no seen-set to drift out of sync with it;
    * a run of this workflow on this repo is live -- the board stays dry while
      the sweep that refills it is still going, and that is not new evidence.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  alias Custode.Backlog
  alias Custode.Feed
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Run

  @advisor_id "advisor-dryness"

  # The workflow a dry board asks for: the five-miner deep dig, the one
  # catalog entry whose output feeds the fleet directly.
  @workflow "backlog-sweep"

  @window_days 7
  @dry_max 2
  @min_sweeps 5

  @yield_events ["needs_approval", "needs_input", "repo_verb"]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    signals = proposable()

    proposed =
      Enum.count(signals, fn signal ->
        match?({:ok, _proposal}, Launch.propose(@workflow, signal.repo, why: why(signal)))
      end)

    Feed.record(%{
      event: "sensor",
      agent: "custode",
      sensor_id: @advisor_id,
      summary: "#{@advisor_id}: #{proposed} launch gate(s) raised on a dry board"
    })

    :ok
  end

  @doc "The advisor grade (#262): deterministic reads, zero tokens."
  def grade, do: :deterministic

  @doc """
  What the fleet's repos look like right now: one observation per repo the
  roster serves, carrying its board read and its routines' recent activity.
  """
  def observe do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@window_days * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    routines =
      Custode.Routine.all()
      |> Enum.filter(&(&1.cron != :manual and is_binary(Map.get(&1, :repo))))
      |> Enum.group_by(& &1.repo)

    counts = event_counts(routines |> Map.values() |> List.flatten() |> Enum.map(& &1.id), since)

    for {repo, repo_routines} <- routines do
      ids = Enum.map(repo_routines, & &1.id)

      %{
        repo: repo,
        routines: ids,
        sweeps: tally(counts, ids, ["turn"]),
        yields: tally(counts, ids, @yield_events),
        board: Backlog.read(repo)
      }
    end
  end

  @doc """
  The repos whose board is dry AND whose routines have gone quiet. Pure over
  observations, so the rule is testable without proposing anything.
  """
  def suggest(observations) do
    for obs <- observations,
        {:ok, board} <- [obs.board],
        board.workable <= @dry_max,
        obs.sweeps >= @min_sweeps,
        obs.yields == 0 do
      Map.put(obs, :board, board)
    end
  end

  @doc """
  The signals that survive the gate suppressions: what `perform/1` will
  actually propose.
  """
  def proposable do
    live =
      MapSet.new(
        Run.list(status: "running") ++ Run.list(status: "budget_paused"),
        &{&1.workflow, &1.repo}
      )

    observe()
    |> suggest()
    |> Enum.reject(fn signal ->
      Map.has_key?(Launch.standing_for(signal.repo), @workflow) or
        MapSet.member?(live, {@workflow, signal.repo}) or
        Launch.recently_rejected?(@workflow, signal.repo)
    end)
  end

  @doc "The one line a gate card carries about why the fleet asked."
  def why(signal) do
    "#{signal.repo} is down to #{signal.board.workable} open workable " <>
      "issue(s) of #{signal.board.open} open, and #{routines(signal.routines)} " <>
      "produced no gate and no verb in #{signal.sweeps} sweeps over #{@window_days}d"
  end

  defp routines([one]), do: one
  defp routines(many), do: "#{length(many)} routines (#{Enum.join(many, ", ")})"

  # One grouped read for the whole fleet: a per-repo query would multiply by
  # the roster for an answer that is the same table scan.
  defp event_counts([], _since), do: %{}

  defp event_counts(agent_ids, since) do
    from(f in "feed_entries",
      where: f.agent in ^agent_ids and f.at > ^since,
      group_by: [f.agent, f.event],
      select: {f.agent, f.event, count(f.id)}
    )
    |> Custode.Repo.all()
    |> Map.new(fn {agent, event, n} -> {{agent, event}, n} end)
  end

  defp tally(counts, agent_ids, events) do
    for id <- agent_ids, event <- events, reduce: 0 do
      total -> total + Map.get(counts, {id, event}, 0)
    end
  end
end
