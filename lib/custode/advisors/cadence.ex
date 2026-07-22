defmodule Custode.Advisors.Cadence do
  @moduledoc """
  The cadence advisor (#124 / #125 slice 1): does each routine's cron match
  how often its sweeps actually find work?

  Beat utilization per routine over the last 7 days, from the feed the
  sweeps already write:

    * a SWEEP is a `turn` entry
    * a YIELD is a sweep-shaped outcome worth the tokens: a gate proposed
      (`needs_approval` / `needs_input`) or a verb run (`repo_verb`)
    * utilization = yielding sweeps / sweeps (approximated by event counts;
      good enough for a suggestion, which a human judges anyway)

  Conservative, evidence-carrying rules -- an advisor that cries wolf gets
  its feed entries ignored:

    * BACK OFF: a sub-daily cron whose utilization over >= 20 sweeps is
      under 10% suggests `@daily` -- the fleet's own night-watch judgment
      (#140, tower-mcp) turned into a rule.
    * RAMP UP (#124's demand half): an @daily repo routine whose sweeps
      mostly yield AND whose served repo carries a real open backlog gets a
      faster cron -- windowed to the operator's observed active hours, so
      the ramp lives inside one static expression (gates resolve when the
      human is around; proposing outside those hours just parks agents).
      Demand reads through the scoped repo read verbs; a repo that cannot
      be read simply produces no suggestion.

  The suggestion key encodes the rounded utilization bucket, so a dismissed
  suggestion returns only when the facts materially change.
  """

  use Custode.Advisor

  import Ecto.Query, only: [from: 2]

  @window_days 7
  @min_sweeps 20
  @low_utilization 0.10
  @rampup_min_sweeps 5
  @rampup_utilization 0.60
  @rampup_min_backlog 5

  @impl Custode.Advisor
  def observe do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@window_days * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    counts =
      Custode.Repo.all(
        from(f in "feed_entries",
          where: f.at > ^since,
          group_by: [f.agent, f.event],
          select: {f.agent, f.event, count(f.id)}
        )
      )
      |> Enum.group_by(fn {agent, _event, _n} -> agent end)

    for routine <- Custode.Routine.all(), routine.cron != :manual do
      by_event =
        counts
        |> Map.get(routine.id, [])
        |> Map.new(fn {_agent, event, n} -> {event, n} end)

      sweeps = Map.get(by_event, "turn", 0)

      yields =
        Map.get(by_event, "needs_approval", 0) +
          Map.get(by_event, "needs_input", 0) +
          Map.get(by_event, "repo_verb", 0)

      %{
        routine_id: routine.id,
        cron: routine.cron,
        repo: routine.repo,
        sweeps: sweeps,
        yields: yields,
        utilization: if(sweeps > 0, do: yields / sweeps, else: 0.0)
      }
    end
  end

  @impl Custode.Advisor
  def suggest(observations) do
    back_offs =
      for obs <- observations,
          obs.sweeps >= @min_sweeps,
          sub_daily?(obs.cron),
          obs.utilization < @low_utilization do
        %{
          routine_id: obs.routine_id,
          field: :cron,
          current: obs.cron,
          proposed: "@daily",
          confidence: confidence(obs),
          evidence:
            "#{obs.yields} of #{obs.sweeps} sweeps produced a gate or verb over " <>
              "#{@window_days}d (#{percent(obs.utilization)}); the cadence is buying no-ops"
        }
      end

    window = operator_hours()

    ramp_ups =
      for obs <- observations,
          not sub_daily?(obs.cron),
          obs.sweeps >= @rampup_min_sweeps,
          obs.utilization >= @rampup_utilization,
          backlog = backlog_size(obs.repo),
          backlog >= @rampup_min_backlog do
        %{
          routine_id: obs.routine_id,
          field: :cron,
          current: obs.cron,
          proposed: "*/30 #{window} * * *",
          confidence: :medium,
          evidence:
            "#{obs.yields} of #{obs.sweeps} daily sweeps yielded (#{percent(obs.utilization)}) " <>
              "and #{backlog} issues wait in the backlog; windowed to the operator's " <>
              "observed active hours (#{window}) so proposals do not park overnight"
        }
      end

    back_offs ++ ramp_ups
  end

  # Demand through the scoped read verb; anything short of an answer means
  # no demand evidence and therefore no suggestion. Deterministic in the
  # advisor sense: one HTTP read, zero tokens.
  defp backlog_size(nil), do: 0

  defp backlog_size(repo) do
    case Custode.Repository.list_issues(repo) do
      {:ok, issues} -> length(issues)
      _unreadable -> 0
    end
  rescue
    _error -> 0
  catch
    :exit, _reason -> 0
  end

  # The operator's active hours, learned from when gates actually get
  # resolved (local tz, 14 days), padded an hour each side; a sparse
  # history falls back to 9-18.
  defp operator_hours do
    tz = Application.get_env(:custode, :timezone, "Etc/UTC")

    hours =
      Custode.Repo.all(
        Ecto.Query.from(g in "gates",
          where: g.status != "open",
          select: g.updated_at,
          limit: 200,
          order_by: [desc: g.updated_at]
        )
      )
      |> Enum.flat_map(fn stamp -> resolved_hour(stamp, tz) end)

    if length(hours) >= 5 do
      "#{max(Enum.min(hours) - 1, 0)}-#{min(Enum.max(hours) + 1, 23)}"
    else
      "9-18"
    end
  end

  defp resolved_hour(%NaiveDateTime{} = naive, tz) do
    case DateTime.from_naive(naive, "Etc/UTC") do
      {:ok, utc} -> [DateTime.shift_zone!(utc, tz).hour]
      _error -> []
    end
  rescue
    _error -> []
  end

  defp resolved_hour(_other, _tz), do: []

  @impl Custode.Advisor
  def key(suggestion) do
    "cadence:#{suggestion.routine_id}:#{suggestion.current}->#{suggestion.proposed}"
  end

  # a cron that fires more than once a day: any minute-field expression
  # (@daily/@weekly/@monthly and friends are the not-sub-daily set)
  defp sub_daily?("@" <> _shorthand), do: false
  defp sub_daily?(_expression), do: true

  defp confidence(%{sweeps: sweeps}) when sweeps >= 60, do: :high
  defp confidence(_obs), do: :medium

  defp percent(ratio), do: "#{round(ratio * 100)}%"
end
