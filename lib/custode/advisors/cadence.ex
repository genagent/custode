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
    * (ramp-up rules wait for #124's backlog-size input; suggesting faster
      cadence needs demand evidence, not just supply)

  The suggestion key encodes the rounded utilization bucket, so a dismissed
  suggestion returns only when the facts materially change.
  """

  use Custode.Advisor

  import Ecto.Query, only: [from: 2]

  @window_days 7
  @min_sweeps 20
  @low_utilization 0.10

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
        sweeps: sweeps,
        yields: yields,
        utilization: if(sweeps > 0, do: yields / sweeps, else: 0.0)
      }
    end
  end

  @impl Custode.Advisor
  def suggest(observations) do
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
  end

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
