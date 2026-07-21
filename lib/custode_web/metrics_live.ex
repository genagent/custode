defmodule CustodeWeb.MetricsLive do
  @moduledoc """
  The metrics page (#78): spend and token throughput per day (stacked by
  agent), turn outcomes, and gate latency -- the human-loop health metric.
  Computed on mount from the ledger and gates tables; refreshed on the
  same PubSub events as everything else, coalesced to at most once per
  few seconds since these queries scan more than a tile refresh.
  """

  use Phoenix.LiveView

  import CustodeWeb.Charts
  import CustodeWeb.Components, only: [page: 1, usd: 1, tok: 1]

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

  def handle_info(_event, %{assigns: %{refresh_queued: true}} = socket), do: {:noreply, socket}

  def handle_info(_event, socket) do
    Process.send_after(self(), :coalesced_refresh, @coalesce_ms)
    {:noreply, assign(socket, refresh_queued: true)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:metrics}>
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
          <div class="stat-desc">last {length(@gates)} gates</div>
        </div>
      </div>

      <div class="grid grid-cols-1 gap-6 xl:grid-cols-2">
        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            spend per day <span class="text-xs font-normal">(last {@days_shown}d, stacked by agent)</span>
          </h3>
          <.stacked_days days={@daily} agents={@agents} metric={:usd} format={&"$#{usd(&1)}"} />
          <.legend agents={@agents} />
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            tokens per day <span class="text-xs font-normal">(throughput, stacked by agent)</span>
          </h3>
          <.stacked_days days={@daily} agents={@agents} metric={:tokens} format={&tok/1} />
          <.legend agents={@agents} />
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            turns per day <span class="text-xs font-normal">(green ok, red failed)</span>
          </h3>
          <div class="flex h-32 items-end gap-1">
            <div
              :for={{date, counts} <- Enum.sort(@turns)}
              class="relative flex h-full flex-1 flex-col-reverse"
              title={"#{date}: #{counts.ok} ok, #{counts.failed} failed"}
            >
              <div class="mt-auto"></div>
              <div class="w-full bg-success" style={"height: #{turn_percent(counts.ok, @turn_max)}%"}>
              </div>
              <div class="w-full bg-error" style={"height: #{turn_percent(counts.failed, @turn_max)}%"}>
              </div>
              <span class="absolute -bottom-5 left-0 right-0 truncate text-center text-[9px] text-base-content/40">
                {String.slice(date, 8, 2)}
              </span>
            </div>
          </div>
          <div class="h-5"></div>
        </section>

        <section class="rounded-lg bg-base-100 p-4 shadow-sm">
          <h3 class="mb-3 font-semibold text-base-content/70">
            gate latency <span class="text-xs font-normal">(open &rarr; resolved; the human loop)</span>
          </h3>
          <.gate_latency gates={@gates} median={@gate_median} />
        </section>
      </div>
    </.page>
    """
  end

  defp refresh(socket) do
    daily = Custode.Metrics.daily_by_agent(@days)
    turns = Custode.Metrics.turns_by_day(@days)
    {gates, gate_median} = Custode.Metrics.gate_latencies()

    agents =
      daily
      |> Enum.flat_map(fn {_date, by_agent} -> Map.keys(by_agent) end)
      |> Enum.uniq()
      |> Enum.sort()

    turn_max =
      turns
      |> Enum.map(fn {_date, counts} -> counts.ok + counts.failed end)
      |> Enum.max(fn -> 1 end)

    today = Date.utc_today() |> Date.to_iso8601()

    assign(socket,
      tokens_today: Custode.SpendLedger.fleet_today_tokens(),
      turns_today: Map.get(turns, today, %{ok: 0, failed: 0}),
      days_shown: @days,
      daily: daily,
      turns: turns,
      turn_max: max(turn_max, 1),
      agents: agents,
      gates: gates,
      gate_median: gate_median,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  defp turn_percent(count, max), do: Float.round(count / max * 100, 2)
end
