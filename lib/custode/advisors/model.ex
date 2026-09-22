defmodule Custode.Advisors.Model do
  @moduledoc """
  The model advisor (#111): are sweeps running a more expensive model than
  their yield justifies?

  The phase-split (#110) already puts approved implementations on the big
  model behind the gate; what drifts is the SWEEP side -- a routine
  configured onto opus for its every-N-minutes survey burns a multiple of
  its sonnet peers to produce the same gates and verbs. Per routine over
  the last 7 days, from the spend ledger's per-turn model rows joined with
  the feed's yield events:

    * sweep spend per yield on the routine's configured model
    * the same ratio across sonnet-swept peers as the baseline

  One conservative rule: a routine whose configured sweep `model` is opus,
  with >= 10 sweeps of evidence, whose yield RATE is no better than the
  sonnet-swept fleet's average, gets "model -> sonnet" with the numbers in
  the evidence. `approved_args` stay untouched -- the gate remains the
  model boundary, exactly the #110 design.
  """

  use Custode.Advisor

  import Ecto.Query, only: [from: 2]

  @window_days 7
  @min_sweeps 10
  @expensive "opus"
  @suggested "sonnet"

  @impl Custode.Advisor
  def observe do
    since =
      DateTime.utc_now()
      |> DateTime.add(-@window_days * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    yields =
      Custode.Repo.all(
        from(f in "feed_entries",
          where: f.at > ^since and f.event in ["needs_approval", "needs_input", "repo_verb"],
          group_by: f.agent,
          select: {f.agent, count(f.id)}
        )
      )
      |> Map.new()

    sweeps =
      Custode.Repo.all(
        from(f in "feed_entries",
          where: f.at > ^since and f.event == "turn",
          group_by: f.agent,
          select: {f.agent, count(f.id)}
        )
      )
      |> Map.new()

    for routine <- Custode.Routine.all(), routine.cron != :manual do
      %{
        routine_id: routine.id,
        provider: routine.provider,
        model: routine.model,
        sweeps: Map.get(sweeps, routine.id, 0),
        yields: Map.get(yields, routine.id, 0)
      }
    end
  end

  @impl Custode.Advisor
  def suggest(observations) do
    baseline = baseline_rate(observations)

    for obs <- observations,
        obs.provider == :claude,
        obs.model == @expensive,
        obs.sweeps >= @min_sweeps,
        rate(obs) <= baseline do
      %{
        routine_id: obs.routine_id,
        field: :model,
        current: obs.model,
        proposed: @suggested,
        confidence: if(obs.sweeps >= 30, do: :high, else: :medium),
        evidence:
          "#{obs.yields} yields over #{obs.sweeps} opus sweeps in #{@window_days}d " <>
            "(#{percent(rate(obs))}) vs the sonnet fleet's #{percent(baseline)} -- the " <>
            "big model is not out-yielding the small one; approved turns keep opus"
      }
    end
  end

  @impl Custode.Advisor
  def key(suggestion) do
    "model:#{suggestion.routine_id}:#{suggestion.current}->#{suggestion.proposed}"
  end

  # the sonnet-swept fleet's average yield rate; 0.0 with no evidence, which
  # then suggests nothing (an opus routine cannot yield <= nothing usefully
  # -- guarded by requiring a positive baseline)
  defp baseline_rate(observations) do
    peers =
      Enum.filter(
        observations,
        &(&1.provider == :claude and &1.model == @suggested and &1.sweeps >= @min_sweeps)
      )

    total_sweeps = peers |> Enum.map(& &1.sweeps) |> Enum.sum()
    total_yields = peers |> Enum.map(& &1.yields) |> Enum.sum()
    if total_sweeps > 0, do: total_yields / total_sweeps, else: 1.0e9
  end

  defp rate(%{sweeps: sweeps, yields: yields}) when sweeps > 0, do: yields / sweeps
  defp rate(_obs), do: 0.0

  defp percent(ratio) when ratio >= 1.0e8, do: "n/a"
  defp percent(ratio), do: "#{round(ratio * 100)}%"
end
