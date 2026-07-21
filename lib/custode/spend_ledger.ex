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
      # per-turn tokens from ClaudeWrapper.Result.usage/1 (#30): the truer
      # measure of work on a subscription, where cost_usd is notional
      field(:input_tokens, :integer)
      field(:output_tokens, :integer)
      field(:cache_creation_tokens, :integer)
      field(:cache_read_tokens, :integer)
      field(:stop_reason, :string)
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

  # :telemetry DETACHES a handler that raises -- one transient Repo/file
  # error would silently kill this pipeline until restart (audit
  # 2026-07-21). Never raise out of a handler.
  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      require Logger

      Logger.error(
        "Custode.SpendLedger handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  defp do_handle_event([:oban_claude, :run, outcome], measurements, meta, _config) do
    case meta do
      %{job: %{meta: %{"agent_id" => agent_id}}} ->
        record(
          agent_id,
          measurements.cost_usd,
          if(outcome == :stop, do: "turn", else: "failed"),
          usage_of(meta)
        )

      _no_agent ->
        :ok
    end
  end

  # error results carry no usage; nil columns are the honest record
  defp usage_of(%{result: %ClaudeWrapper.Result{} = result}) do
    case ClaudeWrapper.Result.usage(result) do
      nil -> [stop_reason: ClaudeWrapper.Result.stop_reason(result)]
      usage -> [usage: usage, stop_reason: ClaudeWrapper.Result.stop_reason(result)]
    end
  end

  defp usage_of(_meta), do: []

  @doc "Record spend for an agent and enforce its budget (if it is a routine with one)."
  def record(agent_id, cost_usd, outcome \\ "turn", opts \\ []) when is_number(cost_usd) do
    usage = opts[:usage] || %{}

    Repo.insert!(%Entry{
      agent_id: agent_id,
      cost_usd: cost_usd * 1.0,
      outcome: outcome,
      input_tokens: usage[:input],
      output_tokens: usage[:output],
      cache_creation_tokens: usage[:cache_creation],
      cache_read_tokens: usage[:cache_read],
      stop_reason: opts[:stop_reason]
    })

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

  @doc """
  An agent's throughput tokens (input + output + cache creation; cache
  reads excluded, consistent with claude_wrapper's `total`) since the start
  of the current UTC day.
  """
  def today_tokens(agent_id) do
    Repo.one(
      from(s in Entry,
        where: s.agent_id == ^agent_id and s.inserted_at >= ^start_of_utc_day(),
        select:
          coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
            coalesce(sum(s.cache_creation_tokens), 0)
      )
    ) || 0
  end

  @doc "Everyone's throughput tokens since the start of the current UTC day."
  def fleet_today_tokens do
    Repo.one(
      from(s in Entry,
        where: s.inserted_at >= ^start_of_utc_day(),
        select:
          coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
            coalesce(sum(s.cache_creation_tokens), 0)
      )
    ) || 0
  end

  defp enforce(agent_id) do
    case Custode.Routine.get(agent_id) do
      nil -> :ok
      routine -> enforce_rails(routine, agent_id)
    end
  end

  defp enforce_rails(routine, agent_id) do
    cond do
      over = usd_overage(routine, agent_id) -> pause(agent_id, over)
      over = token_overage(routine, agent_id) -> pause(agent_id, over)
      true -> :ok
    end
  end

  defp usd_overage(%{daily_budget_usd: budget}, agent_id) when is_number(budget) do
    spent = today(agent_id)
    if spent > budget, do: "daily budget hit: $#{Float.round(spent, 4)} of $#{budget}"
  end

  defp usd_overage(_routine, _agent_id), do: nil

  defp token_overage(%{daily_budget_tokens: budget}, agent_id) when is_integer(budget) do
    spent = today_tokens(agent_id)
    if spent > budget, do: "daily token rail hit: #{spent} of #{budget} tokens"
  end

  defp token_overage(_routine, _agent_id), do: nil

  defp pause(agent_id, reason) do
    case ObanClaude.Agent.status(agent_id) do
      {:ok, status} when status not in [:paused, :offline] ->
        ObanClaude.Agent.emergency_pause(agent_id)

        Custode.Feed.record(
          %{
            event: "budget_paused",
            agent: agent_id,
            action: reason <> " -- paused; resume is a human override"
          },
          notify: true
        )

        :ok

      _unenforceable ->
        :ok
    end
  end

  defp start_of_utc_day do
    DateTime.new!(Date.utc_today(), ~T[00:00:00], "Etc/UTC")
  end
end
