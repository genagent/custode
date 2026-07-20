defmodule Custode.SpendLedger do
  @moduledoc """
  The durable money trail: one row per claude turn (successes and failures
  both carry spend), written from the same run telemetry the feed uses --
  so spend survives restarts, unlike the in-process `info/1` counters.

  Budgets: a routine with `:daily_budget_usd` (per-entry, or the shared
  `config :custode, :daily_budget_usd` default) is auto-paused the moment its
  UTC-day total crosses the cap -- `emergency_pause` through the ordinary
  facade, with a `budget_paused` feed entry (and desktop notification).
  Resuming is an explicit human override; the next turn's spend re-pauses if
  still over.

  Honest limitation: a restart clears the pause (agents cold-start from the
  crontab), so an over-budget routine leaks at most ONE more turn after a
  restart before its spend re-triggers the pause.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    schema "spend" do
      field(:agent_id, :string)
      field(:cost_usd, :float)
      field(:outcome, :string, default: "turn")
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end

  @events [
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-spend-ledger", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:oban_claude, :run, outcome], measurements, meta, _config) do
    case meta do
      %{job: %{meta: %{"agent_id" => agent_id}}} ->
        record(agent_id, measurements.cost_usd, if(outcome == :stop, do: "turn", else: "failed"))

      _no_agent ->
        :ok
    end
  end

  @doc "Record spend for an agent and enforce its budget (if it is a routine with one)."
  def record(agent_id, cost_usd, outcome \\ "turn") when is_number(cost_usd) do
    Repo.insert!(%Entry{agent_id: agent_id, cost_usd: cost_usd * 1.0, outcome: outcome})
    enforce(agent_id)
    :ok
  end

  @doc "An agent's spend since the start of the current UTC day."
  def today(agent_id), do: total(agent_id, start_of_utc_day())

  @doc "An agent's total spend since `since` (a DateTime)."
  def total(agent_id, since) do
    Repo.aggregate(
      from(s in Entry, where: s.agent_id == ^agent_id and s.inserted_at >= ^since),
      :sum,
      :cost_usd
    ) || 0.0
  end

  @doc "Everyone's spend since the start of the current UTC day."
  def fleet_today do
    Repo.aggregate(
      from(s in Entry, where: s.inserted_at >= ^start_of_utc_day()),
      :sum,
      :cost_usd
    ) || 0.0
  end

  defp enforce(agent_id) do
    with %{daily_budget_usd: budget} when is_number(budget) <- Custode.Routine.get(agent_id),
         spent when spent > budget <- today(agent_id),
         {:ok, status} when status not in [:paused, :offline] <-
           ObanClaude.Agent.status(agent_id) do
      ObanClaude.Agent.emergency_pause(agent_id)

      Custode.Feed.record(
        %{
          event: "budget_paused",
          agent: agent_id,
          action:
            "daily budget hit: $#{Float.round(spent, 4)} of $#{budget} -- paused; resume is a human override"
        },
        notify: true
      )
    else
      _within_budget_or_unenforceable -> :ok
    end

    :ok
  end

  defp start_of_utc_day do
    DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
  end
end
