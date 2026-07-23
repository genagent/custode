defmodule Custode.Digest do
  @moduledoc """
  The window digest (#259 / design 004 D2): one deterministic builder, many
  readers. It reads a compact, typed summary of a time window off the
  telemetry projections the fleet already writes -- the spend ledger, the
  gates table, the feed -- and renders to both a MAP (for code, e.g. a
  judgment advisor's observation) and MARKDOWN (for prompts and humans).

  Pure queries, ZERO tokens: `build/1` composes `Custode.Metrics` (which
  already holds the windowed spend/turn/gate reads) plus one small
  failure-kind query. It never keeps bespoke counters -- telemetry is the
  only substrate (D1).

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

  alias Custode.{Feed, Metrics, Repo}
  alias Custode.SpendLedger.Entry

  @default_days 7

  @doc """
  Build the digest for the last `days` UTC days (default 7). Returns a typed
  map; every section is present even when the window is quiet.
  """
  def build(days \\ @default_days) when is_integer(days) and days > 0 do
    by_agent = aggregate_agents(Metrics.daily_by_agent(days))
    turns = turn_totals(Metrics.turns_by_day(days))
    {gates, median_minutes} = Metrics.gate_latencies()
    failed = failed_by_agent(days)

    %{
      window_days: days,
      spend: %{
        total_usd: by_agent |> Enum.map(fn {_a, m} -> m.usd end) |> sum() |> round2(),
        total_tokens: by_agent |> Enum.map(fn {_a, m} -> m.tokens end) |> sum(),
        by_agent: by_agent,
        by_model: Metrics.by_model(days)
      },
      sweeps: %{
        total: turns.ok + turns.failed,
        ok: turns.ok,
        failed: turns.failed,
        yield_pct: pct(turns.ok, turns.ok + turns.failed)
      },
      gates: %{count: length(gates), median_minutes: median_minutes, recent: gates},
      failures: %{total: failures_total(failed), by_kind: failures_by_kind(days)},
      suggestions: standing_suggestions(),
      anomalies: anomalies(failed)
    }
  end

  @doc "Render a digest map as compact markdown for prompts, reports, and humans."
  def to_markdown(%{} = d) do
    """
    ## Fleet digest -- last #{d.window_days}d

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

  # --- queries ---------------------------------------------------------

  # sum the per-day, per-agent spend into one row per agent over the window
  defp aggregate_agents(daily) do
    Enum.reduce(daily, %{}, fn {_date, by_agent}, acc -> merge_day(acc, by_agent) end)
  end

  defp merge_day(acc, by_agent) do
    Enum.reduce(by_agent, acc, fn {agent, %{usd: usd, tokens: tokens}}, inner ->
      Map.update(inner, agent, %{usd: usd, tokens: tokens}, &add_spend(&1, usd, tokens))
    end)
  end

  defp add_spend(cur, usd, tokens), do: %{usd: cur.usd + usd, tokens: cur.tokens + tokens}

  defp turn_totals(by_day) do
    Enum.reduce(by_day, %{ok: 0, failed: 0}, fn {_date, %{ok: ok, failed: failed}}, acc ->
      %{ok: acc.ok + ok, failed: acc.failed + failed}
    end)
  end

  # failed turns grouped by agent over the window (for anomalies)
  defp failed_by_agent(days) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since(days) and s.outcome != "turn",
        group_by: s.agent_id,
        select: {s.agent_id, count(s.id)}
      )
    )
    |> Map.new()
  end

  # failed turns grouped by their stop_reason -- the failure KINDS
  defp failures_by_kind(days) do
    Repo.all(
      from(s in Entry,
        where: s.inserted_at >= ^since(days) and s.outcome != "turn",
        group_by: s.stop_reason,
        select: {s.stop_reason, count(s.id)}
      )
    )
    |> Map.new(fn {kind, count} -> {kind || "(unknown)", count} end)
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

  # cheap, honest anomalies for slice 1: agents whose failures cluster in the
  # window. Rail hits and silent sensors arrive with slice 4's telemetry.
  defp anomalies(failed_by_agent) do
    failed_by_agent
    |> Enum.filter(fn {_agent, n} -> n >= 2 end)
    |> Enum.sort_by(fn {_agent, n} -> -n end)
    |> Enum.map(fn {agent, n} -> "#{agent}: #{n} failed turns in the window" end)
  end

  # match daily_by_agent's window (days calendar days including today)
  defp since(days) do
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

  # --- number helpers --------------------------------------------------

  defp sum(list), do: Enum.sum(list)
  defp pct(_n, 0), do: 0
  defp pct(n, total), do: round(n / total * 100)
  defp round2(x), do: Float.round(x * 1.0, 2)
end
