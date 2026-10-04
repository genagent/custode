defmodule CustodeWeb.MetricsLive do
  @moduledoc """
  The metrics page (#78): spend and token throughput per day (grouped by
  agent and workflow), turn outcomes, and gate latency -- the human-loop health metric.
  Computed on mount from the ledger and gates tables; refreshed on the
  same PubSub events as everything else, coalesced to at most once per
  few seconds since these queries scan more than a tile refresh.
  """

  use Phoenix.LiveView

  import CustodeWeb.Charts
  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components, only: [page: 1, usd: 1, tok: 1]
  import CustodeWeb.DigestPanel, only: [digest_panel: 1]

  alias Custode.Gates.Grant

  @days 14
  @coalesce_ms 5_000

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, socket |> assign(refresh_queued: false) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info(:coalesced_refresh, socket) do
    {:noreply, socket |> assign(refresh_queued: false) |> refresh()}
  end

  def handle_info(event, %{assigns: %{refresh_queued: true}} = socket),
    do: {:noreply, AttentionSnapshot.refresh_for(socket, event)}

  def handle_info(event, socket) do
    Process.send_after(self(), :coalesced_refresh, @coalesce_ms)
    {:noreply, socket |> AttentionSnapshot.refresh_for(event) |> assign(refresh_queued: true)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:metrics}>
      <div class="stats stats-horizontal mb-6 w-full bg-base-100 shadow-sm">
        <div class="stat">
          <div class="stat-title">fleet today</div>
          <div class="stat-value text-2xl">${CustodeWeb.Components.usd(@fleet_today)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">tokens today</div>
          <div class="stat-value text-2xl">{CustodeWeb.Components.tok(@tokens_today)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">turns today</div>
          <div class="stat-value text-2xl">{@turns_today.ok}</div>
          <div class="stat-desc">
            <span :if={@turns_today.failed > 0} class="text-error">
              {@turns_today.failed} failed
            </span>
            <span :if={@turns_today.failed == 0}>none failed</span>
          </div>
        </div>
        <div class="stat">
          <div class="stat-title">median gate wait</div>
          <div class="stat-value text-2xl">{@gate_median}m</div>
          <div class="stat-desc">last {length(@gates)} {if length(@gates) == 1, do: "gate", else: "gates"}</div>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <section class="min-w-0 rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            Spend per day <span class="text-xs font-normal">(last {@days_shown} days)</span>
          </h3>
          <.daily_chart
            id="daily-spend"
            chart={@charts.usd}
            label="Spend per day"
            format={&chart_usd/1}
            exact_format={&"#{&1} USD"}
          />
        </section>

        <section class="min-w-0 rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            Tokens per day <span class="text-xs font-normal">(throughput)</span>
          </h3>
          <.daily_chart
            id="daily-tokens"
            chart={@charts.tokens}
            label="Tokens per day"
            format={&tok/1}
            exact_format={&"#{&1} tokens"}
          />
        </section>

        <section class="min-w-0 rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">Turns per day</h3>
          <.daily_chart
            id="daily-turns"
            chart={@turn_chart}
            label="Turns per day"
            format={&to_string/1}
            exact_format={&"#{&1} #{if &1 == 1, do: "turn", else: "turns"}"}
          />
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            gate latency <span class="text-xs font-normal">(open &rarr; resolved; the human loop)</span>
          </h3>
          <.gate_latency gates={@gates} median={@gate_median} />
        </section>

        <%!-- Whether a gate is a decision or a formality (#448). An agent at
              100% over many gates is one whose gates cost latency and buy
              nothing; that is the evidence for relaxing a class (#451). --%>
        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            approval rate <span class="text-xs font-normal">(decided approval gates, all time)</span>
          </h3>
          <p :if={@approval_rates == []} class="text-sm text-base-content/50">
            no decided approval gates yet
          </p>
          <div :if={@approval_rates != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>agent</th>
                  <th class="text-right">approved</th>
                  <th class="text-right">rejected</th>
                  <th class="text-right">rate</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @approval_rates}>
                  <td class="font-mono">{row.agent_id}</td>
                  <td class="text-right font-mono">{row.approved}</td>
                  <td class="text-right font-mono">{row.rejected}</td>
                  <td class="text-right font-mono">{round(row.rate * 100)}%</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- The same question by CLASS of action (#451). Only gates raised
              since agents began declaring a class are counted, so this table
              starts empty and fills as the fleet works. --%>
        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            approval rate by class
            <span class="text-xs font-normal">(gates that declared one)</span>
          </h3>
          <p :if={@approval_rates_by_class == []} class="text-sm text-base-content/50">
            no decided gate has declared a class yet
          </p>
          <div :if={@approval_rates_by_class != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>class</th>
                  <th>risk</th>
                  <th class="text-right">approved</th>
                  <th class="text-right">rejected</th>
                  <th class="text-right">rate</th>
                  <th class="text-right">median wait</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @approval_rates_by_class}>
                  <td class="font-mono">{row.class}</td>
                  <td class="font-mono text-base-content/60">{row.risk || "-"}</td>
                  <td class="text-right font-mono">{row.approved}</td>
                  <td class="text-right font-mono">{row.rejected}</td>
                  <td class="text-right font-mono">{round(row.rate * 100)}%</td>
                  <td class="text-right font-mono">{row.median_wait_min}m</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <%!-- Writes made outside an approved action (#451). Observed, not yet
              refused: this table is what says whether refusing is safe. --%>
        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            writes outside a grant
            <span class="text-xs font-normal">(mode: {@grant_mode})</span>
          </h3>
          <p :if={@grant_observations == []} class="text-sm text-base-content/50">
            none observed: every write verb ran inside an approved action of its class
          </p>
          <div :if={@grant_observations != []} class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>agent</th>
                  <th>verb</th>
                  <th>verdict</th>
                  <th class="text-right">count</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @grant_observations}>
                  <td class="font-mono">{row.agent}</td>
                  <td class="font-mono">{row.verb}</td>
                  <td class="font-mono">{row.verdict}</td>
                  <td class="text-right font-mono">{row.count}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm xl:col-span-2">
          <h3 class="mb-3 font-semibold text-base-content/70">
            by model
            <span class="text-xs font-normal">
              (last {@days_shown}d -- is opus earning its tokens? #111)
            </span>
          </h3>
          <div class="overflow-x-auto">
            <table class="table table-xs">
              <thead>
                <tr>
                  <th>model</th>
                  <th class="text-right">turns</th>
                  <th class="text-right">failed</th>
                  <th class="text-right">spend</th>
                  <th class="text-right">tokens</th>
                  <th class="text-right">$/turn</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={{model, row} <- Enum.sort_by(@by_model, fn {_m, r} -> -r.usd end)}>
                  <td class="font-mono">{model}</td>
                  <td class="text-right">{row.turns}</td>
                  <td class={["text-right", row.failed > 0 && "text-error"]}>{row.failed}</td>
                  <td class="text-right font-mono">${CustodeWeb.Components.usd(row.usd)}</td>
                  <td class="text-right font-mono">{CustodeWeb.Components.tok(row.tokens)}</td>
                  <td class="text-right font-mono">
                    ${CustodeWeb.Components.usd(row.usd / max(row.turns, 1))}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm xl:col-span-2">
          <.digest_panel id="metrics-digest-panel" digest={@digest} />
        </section>
      </div>
    </.page>
    """
  end

  defp refresh(socket) do
    socket = AttentionSnapshot.refresh(socket)

    charts = Custode.Metrics.daily_charts(@days)
    turns = Custode.Metrics.turns_by_day(@days)
    {gates, gate_median} = Custode.Metrics.gate_latencies()

    today = Date.utc_today() |> Date.to_iso8601()

    assign(socket,
      approval_rates: Custode.Gates.approval_rates(),
      approval_rates_by_class: Custode.Gates.approval_rates_by_class(),
      grant_observations: Grant.observations(),
      grant_mode: Grant.mode(),
      by_model: Custode.Metrics.by_model(@days),
      digest: Custode.Digest.build(7),
      tokens_today: Custode.SpendLedger.fleet_today_tokens(),
      turns_today: Map.get(turns, today, %{ok: 0, failed: 0}),
      days_shown: @days,
      charts: charts,
      turn_chart: turn_chart(turns, today),
      gates: gates,
      gate_median: gate_median,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  defp turn_chart(turns, today) do
    days =
      for {date, counts} <- Enum.sort(turns) do
        %{date: date, total: counts.ok + counts.failed, values: counts}
      end

    series =
      for {key, label} <- [ok: "Successful", failed: "Failed"] do
        total = Enum.sum(Enum.map(days, &Map.fetch!(&1.values, key)))
        %{key: key, kind: :outcome, label: label, total: total}
      end
      |> Enum.sort_by(&{-&1.total, &1.key})

    %{
      metric: :turns,
      today: today,
      days: days,
      series: series,
      max: Enum.max(Enum.map(days, & &1.total), fn -> 0 end),
      total: Enum.sum(Enum.map(days, & &1.total))
    }
  end

  defp chart_usd(value) when value > 0 and value < 0.01, do: "$#{value}"
  defp chart_usd(value), do: "$#{usd(value)}"
end
