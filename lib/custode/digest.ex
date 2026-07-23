defmodule Custode.Digest do
  @moduledoc """
  The window digest (#259 / design 004 D2): one deterministic builder, many
  readers. It reads a compact, typed summary of a time window off the
  telemetry projections the fleet already writes -- the spend ledger, the
  gates table, the feed -- and renders to both a MAP (for code, e.g. a
  judgment advisor's observation) and MARKDOWN (for prompts and humans).

  Pure queries, ZERO tokens: everything is a direct read over a `since`
  timestamp. `build/1` summarizes the last N UTC days; `build_since/1`
  summarizes a precise `[since, now]` window (#263 -- the presence-return
  "while you were away" view wants exactly this, an arbitrary gap rather than
  whole days). It never keeps bespoke counters -- telemetry is the only
  substrate (D1).

  The point is to keep LLM eyes OFF raw telemetry. A judgment call reads two
  hundred lines of curated summary here, never two hundred thousand events.
  Three readers, one builder:

    * judgment advisors (#262) -- the digest IS their `observe/0`
    * the presence-return flow (#263 / #141) -- the "while you were away"
      digest on operator return
    * the human -- the morning-report pattern, and eventually a panel (#100)

  What is NOT here yet: rail-hit and silent-sensor anomalies want the
  emit-from-birth telemetry slice 4 (#261) adds; `anomalies/1` surfaces only
  what is cheaply derivable today (turn-failure clusters). Extend the digest
  deterministically as the stream grows -- never by prompting raw telemetry.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo}
  alias Custode.SpendLedger.Entry

  @default_days 7

  @doc """
  Build the digest for the last `days` UTC days (default 7). Returns a typed
  map; every section is present even when the window is quiet.
  """
  def build(days \\ @default_days) when is_integer(days) and days > 0 do
    days |> days_ago() |> build_since() |> Map.put(:window_days, days)
  end

  @doc """
  Build the digest for the precise window `[since, now]` (#263). Same typed
  map as `build/1`, carrying `:since` instead of `:window_days` -- used for an
  operator's away window, which is an arbitrary gap, not whole days.
  """
  def build_since(%DateTime{} = since) do
    by_agent = spend_by_agent(since)
    turns = turn_totals(since)
    failed = failed_by_agent(since)
    {gates, median_minutes} = gates_since(since)

    %{
      since: since,
      spend: %{
        total_usd: by_agent |> Enum.map(fn {_a, m} -> m.usd end) |> Enum.sum() |> round2(),
        total_tokens: by_agent |> Enum.map(fn {_a, m} -> m.tokens end) |> Enum.sum(),
        by_agent: by_agent,
        by_model: spend_by_model(since)
      },
      sweeps: %{
        total: turns.ok + turns.failed,
        ok: turns.ok,
        failed: turns.failed,
        yield_pct: pct(turns.ok, turns.ok + turns.failed)
      },
      gates: %{count: length(gates), median_minutes: median_minutes, recent: gates},
      failures: %{total: failures_total(failed), by_kind: failures_by_kind(since)},
      suggestions: standing_suggestions(),
      anomalies: anomalies(failed) ++ rail_hits(since)
    }
  end

  @doc "Render a digest map as compact markdown for prompts, reports, and humans."
  def to_markdown(%{} = d) do
    """
    ## Fleet digest -- #{window_label(d)}

    **Spend** $#{d.spend.total_usd} / #{d.spend.total_tokens} tokens
    #{agent_lines(d.spend.by_agent)}

    **Sweeps** #{d.sweeps.total} turns, #{d.sweeps.ok} ok / #{d.sweeps.failed} failed (#{d.sweeps.yield_pct}% yield)

    **Gates** #{d.gates.count} resolved, median #{d.gates.median_minutes} min to resolution

    **Failures** #{d.failures.total} total#{kind_lines(d.failures.by_kind)}

    **Standing suggestions** #{length(d.suggestions)}
    #{suggestion_lines(d.suggestions)}

    **Anomalies**
    #{anomaly_lines(d.anomalies)}
    """
    |> String.trim_trailing()
    |> Kernel.<>("\n")
  end

  defp window_label(%{window_days: days}), do: "last #{days}d"
  defp window_label(%{since: since}), do: "since #{ago(since)}"

  # --- queries (all over a since timestamp) ----------------------------

  defp spend_by_agent(since) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since,
        group_by: s.agent_id,
        select: {
          s.agent_id,
          sum(s.cost_usd),
          coalesce(sum(s.input_tokens), 0) + coalesce(sum(s.output_tokens), 0) +
            coalesce(sum(s.cache_creation_tokens), 0)
        }
      )
    )
    |> Map.new(fn {agent, usd, tokens} -> {agent, %{usd: usd || 0.0, tokens: tokens || 0}} end)
  end

  defp spend_by_model(since) do
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
    |> Map.new(fn {model, usd, tokens, turns, failed} ->
      {model || "(unrecorded)",
       %{usd: usd || 0.0, tokens: tokens || 0, turns: turns, failed: failed || 0}}
    end)
  end

  defp turn_totals(since) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since,
        group_by: s.outcome,
        select: {s.outcome, count(s.id)}
      )
    )
    |> Enum.reduce(%{ok: 0, failed: 0}, fn {outcome, n}, acc ->
      key = if outcome == "turn", do: :ok, else: :failed
      Map.update(acc, key, n, &(&1 + n))
    end)
  end

  # failed turns grouped by agent over the window (for anomalies)
  defp failed_by_agent(since) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since and s.outcome != "turn",
        group_by: s.agent_id,
        select: {s.agent_id, count(s.id)}
      )
    )
    |> Map.new()
  end

  # failed turns grouped by their stop_reason -- the failure KINDS
  defp failures_by_kind(since) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since and s.outcome != "turn",
        group_by: s.stop_reason,
        select: {s.stop_reason, count(s.id)}
      )
    )
    |> Map.new(fn {kind, count} -> {kind || "(unknown)", count} end)
  end

  # gates resolved within the window: open -> resolved latency in minutes
  defp gates_since(since) do
    rows =
      Repo.all(
        from(g in Custode.Gates.Gate,
          where: g.status != "open" and g.updated_at >= ^since,
          order_by: [desc: g.id],
          limit: 15,
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

  defp failures_total(failed_by_agent), do: failed_by_agent |> Map.values() |> Enum.sum()

  defp standing_suggestions do
    "advisor_suggestion"
    |> Feed.recent_by_event(limit: 20)
    |> Enum.map(fn s ->
      %{
        advisor: s["advisor"],
        agent: s["agent"],
        field: s["field"],
        current: s["current"],
        proposed: s["proposed"],
        confidence: s["confidence"],
        evidence: s["evidence"]
      }
    end)
  end

  # agents whose failures cluster in the window
  defp anomalies(failed_by_agent) do
    failed_by_agent
    |> Enum.filter(fn {_agent, n} -> n >= 2 end)
    |> Enum.sort_by(fn {_agent, n} -> -n end)
    |> Enum.map(fn {agent, n} -> "#{agent}: #{n} failed turns in the window" end)
  end

  # rail hits (#261): routines that crossed their daily budget rail and paused
  # in the window. The budget_paused events already exist (SpendLedger); the
  # digest just surfaces them. Deduped per agent (one pause is the signal).
  defp rail_hits(since) do
    seconds = DateTime.diff(DateTime.utc_now(), since)

    "budget_paused"
    |> Feed.recent_by_event(limit: 50, since: seconds)
    |> Enum.map(& &1["agent"])
    |> Enum.uniq()
    |> Enum.map(&"#{&1}: hit its daily budget rail and paused")
  end

  # the last N calendar days including today (matches the pre-#263 window)
  defp days_ago(days) do
    Date.utc_today()
    |> Date.add(-(days - 1))
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
  end

  # --- render helpers --------------------------------------------------

  defp agent_lines(by_agent) when map_size(by_agent) == 0, do: "  (quiet)"

  defp agent_lines(by_agent) do
    by_agent
    |> Enum.sort_by(fn {_agent, m} -> -m.usd end)
    |> Enum.map_join("\n", fn {agent, m} ->
      "  - #{agent}: $#{round2(m.usd)} / #{m.tokens} tok"
    end)
  end

  defp kind_lines(by_kind) when map_size(by_kind) == 0, do: ""

  defp kind_lines(by_kind) do
    "\n" <>
      Enum.map_join(by_kind, "\n", fn {kind, count} -> "  - #{kind}: #{count}" end)
  end

  defp suggestion_lines([]), do: "  (none)"

  defp suggestion_lines(suggestions) do
    Enum.map_join(suggestions, "\n", fn s ->
      "  - #{s.advisor} -> #{s.agent}: #{s.field} #{s.current} -> #{s.proposed} (#{s.confidence})"
    end)
  end

  defp anomaly_lines([]), do: "  (none)"
  defp anomaly_lines(anomalies), do: Enum.map_join(anomalies, "\n", &"  - #{&1}")

  # --- number/time helpers ---------------------------------------------

  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n / total * 100)
  defp round2(x), do: Float.round(x * 1.0, 2)

  defp median([]), do: 0

  defp median(values) do
    sorted = Enum.sort(values)
    Enum.at(sorted, div(length(sorted), 2))
  end

  defp diff_minutes(%DateTime{} = closed, %DateTime{} = opened),
    do: div(DateTime.diff(closed, opened), 60)

  defp diff_minutes(closed, opened),
    do: div(NaiveDateTime.diff(to_naive(closed), to_naive(opened)), 60)

  defp to_naive(%DateTime{} = dt), do: DateTime.to_naive(dt)
  defp to_naive(%NaiveDateTime{} = ndt), do: ndt

  defp ago(%DateTime{} = at) do
    minutes = div(DateTime.diff(DateTime.utc_now(), at), 60)

    cond do
      minutes < 1 -> "just now"
      minutes < 60 -> "#{minutes}m ago"
      true -> "#{div(minutes, 60)}h #{rem(minutes, 60)}m ago"
    end
  end
end
