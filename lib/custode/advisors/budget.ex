defmodule Custode.Advisors.Budget do
  @moduledoc """
  The budget advisor (#125's third): do the rails match reality?

  Per routine, the last 7 days of daily spend from the ledger versus its
  configured `daily_budget_usd`. Two conservative rules:

    * **LOWER a slack rail**: every observed day under 30% of the rail,
      with at least 3 active days of evidence -- the rail is guarding
      nothing at its current height, and headroom on a work machine is
      risk, not generosity. Proposes ceil(2x the observed peak).
    * **RAISE a binding rail**: the routine PAUSED on its rail (a
      `budget_paused` feed event in the window) while its work kept
      merging (repo_verb evidence in the same window) -- the rail is
      interrupting production, not runaway. Proposes 1.5x, rounded up.

  Both carry the numbers in the evidence; both are suggestions, and the
  operator remains the actuator.
  """

  use Custode.Advisor

  import Ecto.Query, only: [from: 2]

  @window_days 7
  @slack_ratio 0.30
  @min_active_days 3

  @impl Custode.Advisor
  def observe do
    for routine <- Custode.Routine.all(),
        is_number(routine.daily_budget_usd) do
      series = Custode.Metrics.spend_series(routine.id, @window_days)

      %{
        routine_id: routine.id,
        rail: routine.daily_budget_usd,
        peak: Enum.max(series, fn -> 0.0 end),
        active_days: Enum.count(series, &(&1 > 0.0)),
        paused: paused_in_window?(routine.id),
        producing: producing_in_window?(routine.id)
      }
    end
  end

  @impl Custode.Advisor
  def suggest(observations) do
    Enum.flat_map(observations, fn obs ->
      cond do
        obs.paused and obs.producing ->
          [suggestion(obs, raise_to(obs.rail), :high, raise_evidence(obs))]

        obs.active_days >= @min_active_days and obs.peak < obs.rail * @slack_ratio ->
          [suggestion(obs, lower_to(obs.peak), :medium, slack_evidence(obs))]

        true ->
          []
      end
    end)
  end

  @impl Custode.Advisor
  def key(suggestion) do
    "budget:#{suggestion.routine_id}:#{suggestion.current}->#{suggestion.proposed}"
  end

  defp suggestion(obs, proposed, confidence, evidence) do
    %{
      routine_id: obs.routine_id,
      field: :daily_budget_usd,
      current: obs.rail,
      proposed: proposed,
      confidence: confidence,
      evidence: evidence
    }
  end

  defp raise_to(rail), do: Float.ceil(rail * 1.5)
  defp lower_to(peak), do: max(Float.ceil(peak * 2), 1.0)

  defp raise_evidence(obs) do
    "hit its $#{obs.rail} rail this week while work kept landing -- " <>
      "the rail is interrupting production, not runaway"
  end

  defp slack_evidence(obs) do
    "peak day $#{Float.round(obs.peak, 2)} across #{obs.active_days} active days, " <>
      "under #{round(@slack_ratio * 100)}% of the $#{obs.rail} rail -- unused headroom is risk"
  end

  defp paused_in_window?(routine_id) do
    Custode.Repo.exists?(
      from(f in "feed_entries",
        where: f.agent == ^routine_id and f.event == "budget_paused" and f.at > ^window_start()
      )
    )
  end

  defp producing_in_window?(routine_id) do
    Custode.Repo.exists?(
      from(f in "feed_entries",
        where: f.agent == ^routine_id and f.event == "repo_verb" and f.at > ^window_start()
      )
    )
  end

  defp window_start do
    DateTime.utc_now()
    |> DateTime.add(-@window_days * 24 * 3600, :second)
    |> DateTime.to_iso8601()
  end
end
