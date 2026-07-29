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
      field(:model, :string)
      field(:attempt_id, :string)
      field(:work_item_id, :string)
      field(:mission_id, :string)
      field(:provider, :string)
      field(:legacy_routine_id, :string)
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
          usage_of(meta) ++ [model: model_of(meta), provider: "claude"] ++ dimensions_of(meta)
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

  defp model_of(%{args: %{"model" => model}}), do: model
  defp model_of(_meta), do: nil

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
      stop_reason: opts[:stop_reason],
      model: opts[:model],
      attempt_id: opts[:attempt_id],
      work_item_id: opts[:work_item_id],
      mission_id: opts[:mission_id],
      provider: opts[:provider],
      legacy_routine_id: opts[:legacy_routine_id] || legacy_routine_id(agent_id)
    })

    enforce(agent_id)
    :ok
  end

  @doc "An agent's spend since the start of the current UTC day."
  def today(agent_id), do: total(agent_id, start_of_local_day())

  @doc "An agent's total spend since `since` (a DateTime)."
  def total(agent_id, since) do
    Repo.aggregate(
      from(s in Entry, where: s.agent_id == ^agent_id and s.inserted_at >= ^since),
      :sum,
      :cost_usd
    ) || 0.0
  end

  @doc """
  Everyone's spend since the start of the current day, as `%{agent_id =>
  total}` (#298).

  One grouped query for the whole fleet. Resolving attention costs a spend
  read per agent, and that now happens on every page render, so the per-agent
  `today/1` in a loop was the wrong shape. Agents that have not spent today
  are absent rather than zero: callers default them.
  """
  def today_by_agent do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^start_of_local_day(),
        group_by: s.agent_id,
        select: {s.agent_id, sum(s.cost_usd)}
      )
    )
    |> Map.new()
  end

  @doc """
  The mean cost of one turn across `agent_ids`, as `{mean_usd, sample_size}`,
  or `nil` when those agents have never spent (#271 slice 2).

  What the workflow launch gate's estimate is built from: a node is one
  claude turn, so a repo's observed per-turn cost is the only non-invented
  number available for "what will this dig cost". Free turns count -- a
  sample that quietly dropped the zeroes would read high.

  `:since` (a DateTime) narrows the window; the default is all of history,
  because a repo the fleet has not touched this week is exactly the one an
  estimate matters for.
  """
  def mean_turn_cost(agent_ids, opts \\ []) when is_list(agent_ids) do
    since = Keyword.get(opts, :since, ~U[1970-01-01 00:00:00Z])

    Repo.one(
      from(s in Entry,
        where: s.agent_id in ^agent_ids and s.inserted_at >= ^since,
        select: {avg(s.cost_usd), count(s.id)}
      )
    )
    |> case do
      {_mean, 0} -> nil
      {nil, _count} -> nil
      {mean, count} -> {mean / 1, count}
    end
  end

  @doc "Everyone's spend since the start of the current UTC day."
  def fleet_today do
    Repo.aggregate(
      from(s in Entry, where: s.inserted_at >= ^start_of_local_day()),
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
        where: s.agent_id == ^agent_id and s.inserted_at >= ^start_of_local_day(),
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
        where: s.inserted_at >= ^start_of_local_day(),
        select:
          coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
            coalesce(sum(s.cache_creation_tokens), 0)
      )
    ) || 0
  end

  @doc """
  Boot reconciliation (#6): the auto-pause used to live only in process
  state, so a restart granted every over-budget routine one fresh turn
  before its next spend re-triggered the rail. Now over-rail routines are
  booted directly INTO :paused -- ticks skip them (if_busy: skip) and
  resume stays the human override.
  """
  def reconcile_pauses! do
    for routine <- Custode.Routine.all(), over_rail?(routine) do
      boot_paused(routine)
      routine.id
    end

    :ok
  end

  defp over_rail?(routine) do
    (is_number(routine.daily_budget_usd) and today(routine.id) > routine.daily_budget_usd) or
      (is_integer(routine.daily_budget_tokens) and
         today_tokens(routine.id) > routine.daily_budget_tokens)
  end

  defp boot_paused(routine) do
    start = Custode.Routine.tick_args(routine)["start"]

    case ObanClaude.Agent.start_agent(routine.id,
           args: start["args"],
           approved_args: start["approved_args"],
           job_timeout: start["job_timeout"]
         ) do
      {:ok, _pid} ->
        ObanClaude.Agent.emergency_pause(routine.id)

        Custode.Feed.record(%{
          event: "budget_paused",
          agent: routine.id,
          action: "still over its daily rail after restart -- booted paused (no leak turn)"
        })

        :ok

      {:error, _already_or_other} ->
        :ok
    end
  end

  defp enforce(agent_id) do
    case Custode.Routine.get(agent_id) do
      nil -> :ok
      routine -> enforce_rails(routine, agent_id)
    end
  end

  defp dimensions_of(%{job: %{meta: meta}}) do
    [
      attempt_id: meta["attempt_id"],
      work_item_id: meta["work_item_id"],
      mission_id: meta["mission_id"],
      legacy_routine_id: meta["legacy_routine_id"]
    ]
  end

  defp legacy_routine_id(agent_id) do
    case Custode.Routine.get(agent_id) do
      nil -> nil
      _routine -> agent_id
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

  # "Today" begins at local midnight in the configured :timezone (#17), the
  # same clock the scheduler fires on -- not UTC. With a UTC day, a Pacific
  # operator's rails rolled at 5pm and an overnight session consumed the
  # NEXT day's budget before breakfast (custode-dev, 2026-07-22). Rows are
  # stored UTC; only the boundary shifts.
  defp start_of_local_day do
    tz = Application.get_env(:custode, :timezone, "Etc/UTC")
    local_now = DateTime.now!(tz)

    DateTime.new!(DateTime.to_date(local_now), ~T[00:00:00], tz)
    |> DateTime.shift_zone!("Etc/UTC")
  end
end
