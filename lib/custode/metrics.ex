defmodule Custode.Metrics do
  @moduledoc """
  Read models for the metrics page (#78), all derived from tables the fleet
  already writes: the spend ledger (cost + tokens + outcome per turn) and
  the gates table (opened/resolved timestamps). Pure queries; rendering
  lives in `CustodeWeb.Charts`.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.SpendLedger.Entry

  @doc """
  Per-day, per-agent spend and throughput tokens over the last `days` UTC
  days: `%{date => %{agent => %{usd: x, tokens: n}}}` with every day in the
  range present (empty map when quiet).
  """
  def daily_by_agent(days) do
    since = start_of_day(days - 1)

    rows =
      Repo.all(
        from(s in Entry,
          where: s.inserted_at >= ^since,
          group_by: [fragment("date(?)", s.inserted_at), s.agent_id],
          select: {
            fragment("date(?)", s.inserted_at),
            s.agent_id,
            sum(s.cost_usd),
            coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
              coalesce(sum(s.cache_creation_tokens), 0)
          }
        )
      )

    by_day =
      Enum.reduce(rows, %{}, fn {date, agent, usd, tokens}, acc ->
        Map.update(
          acc,
          date,
          %{agent => %{usd: usd || 0.0, tokens: tokens || 0}},
          &Map.put(&1, agent, %{usd: usd || 0.0, tokens: tokens || 0})
        )
      end)

    for offset <- (days - 1)..0//-1, into: %{} do
      date = Date.utc_today() |> Date.add(-offset) |> Date.to_iso8601()
      {date, Map.get(by_day, date, %{})}
    end
  end

  @doc "Per-day turn outcomes over the last `days`: `%{date => %{ok: n, failed: n}}`."
  def turns_by_day(days) do
    since = start_of_day(days - 1)

    rows =
      Repo.all(
        from(s in Entry,
          where: s.inserted_at >= ^since,
          group_by: [fragment("date(?)", s.inserted_at), s.outcome],
          select: {fragment("date(?)", s.inserted_at), s.outcome, count(s.id)}
        )
      )

    by_day =
      Enum.reduce(rows, %{}, fn {date, outcome, count}, acc ->
        key = if outcome == "turn", do: :ok, else: :failed
        Map.update(acc, date, %{key => count}, &Map.update(&1, key, count, fn n -> n + count end))
      end)

    for offset <- (days - 1)..0//-1, into: %{} do
      date = Date.utc_today() |> Date.add(-offset) |> Date.to_iso8601()
      {date, Map.merge(%{ok: 0, failed: 0}, Map.get(by_day, date, %{}))}
    end
  end

  @doc """
  The human-loop health metric: how long recent gates waited from open to
  resolution. Returns `{gates, median_minutes}` where each gate is
  `%{agent, detail, minutes, status}` (newest first, resolved-ish only).
  """
  def gate_latencies(limit \\ 15) do
    rows =
      Repo.all(
        from(g in Custode.Gates.Gate,
          where: g.status != "open",
          order_by: [desc: g.id],
          limit: ^limit,
          select: %{
            agent: g.agent_id,
            detail: g.detail,
            status: g.status,
            opened: g.inserted_at,
            closed: g.updated_at
          }
        )
      )

    gates =
      for row <- rows do
        minutes = row.closed |> diff_minutes(row.opened) |> max(0)

        %{
          agent: row.agent,
          detail: String.slice(row.detail || "(no description)", 0, 80),
          minutes: minutes,
          status: row.status
        }
      end

    {gates, median(Enum.map(gates, & &1.minutes))}
  end

  @doc """
  Cost, tokens, and outcomes grouped by MODEL over the last `days` --
  the display side of the model-selection ladder (#111): is opus earning
  its tokens, and where. Rows recorded before model tracking land under
  "(unrecorded)".
  """
  def by_model(days) do
    since = start_of_day(days - 1)

    rows =
      Repo.all(
        from(s in Entry,
          where: s.inserted_at >= ^since,
          group_by: s.model,
          select: {
            s.model,
            sum(s.cost_usd),
            coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
              coalesce(sum(s.cache_creation_tokens), 0),
            count(s.id),
            fragment("SUM(CASE WHEN ? != 'turn' THEN 1 ELSE 0 END)", s.outcome)
          }
        )
      )

    for {model, usd, tokens, turns, failed} <- rows, into: %{} do
      {model || "(unrecorded)",
       %{usd: usd || 0.0, tokens: tokens || 0, turns: turns, failed: failed || 0}}
    end
  end

  @doc "The last `days` of one agent's daily spend, oldest first (tile sparkline)."
  def spend_series(agent_id, days) do
    daily = daily_by_agent(days)

    for offset <- (days - 1)..0//-1 do
      date = Date.utc_today() |> Date.add(-offset) |> Date.to_iso8601()
      get_in(daily, [date, agent_id, :usd]) || 0.0
    end
  end

  @doc "Every agent's spend series in one pass: `%{agent => [usd...]}` oldest first."
  def spend_series_by_agent(days) do
    daily = daily_by_agent(days)
    agents = daily |> Enum.flat_map(fn {_date, by_agent} -> Map.keys(by_agent) end) |> Enum.uniq()

    dates =
      for offset <- (days - 1)..0//-1,
          do: Date.utc_today() |> Date.add(-offset) |> Date.to_iso8601()

    for agent <- agents, into: %{} do
      {agent, Enum.map(dates, &(get_in(daily, [&1, agent, :usd]) || 0.0))}
    end
  end

  defp diff_minutes(%DateTime{} = closed, %DateTime{} = opened),
    do: div(DateTime.diff(closed, opened), 60)

  # gates rows written before the utc_datetime_usec migration read back as
  # NaiveDateTime under some adapters; normalize
  defp diff_minutes(closed, opened) do
    div(NaiveDateTime.diff(to_naive(closed), to_naive(opened)), 60)
  end

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = ndt), do: ndt

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp start_of_day(days_back) do
    Date.utc_today()
    |> Date.add(-days_back)
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end
end
