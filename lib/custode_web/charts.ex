defmodule CustodeWeb.Charts do
  @moduledoc """
  Dependency-free charts for the metrics page (#78): stacked CSS columns
  (theme-aware for free -- heights are percentages, colors come from a
  fixed palette), CSS horizontal bars for the gate-latency list, and one
  small SVG polyline for tile sparklines. No JS, no chart library until
  interactivity earns it.
  """

  use Phoenix.Component

  # distinguishable at 12px, stable per agent via index
  @palette ~w(#6366f1 #22c55e #f59e0b #ef4444 #06b6d4 #a855f7 #84cc16 #f97316 #14b8a6 #e11d48 #64748b #eab308)

  @doc "Stable color per agent from the fleet-ordered agent list."
  def color_for(agent, agents) do
    index = Enum.find_index(agents, &(&1 == agent)) || 0
    Enum.at(@palette, rem(index, length(@palette)))
  end

  attr(:days, :map, required: true, doc: "%{date => %{agent => %{usd:, tokens:}}}")
  attr(:agents, :list, required: true)
  attr(:metric, :atom, default: :usd)
  attr(:format, :any, required: true)

  @doc "Stacked per-agent daily columns for a metric (:usd or :tokens)."
  def stacked_days(assigns) do
    totals =
      for {_date, by_agent} <- assigns.days do
        by_agent |> Map.values() |> Enum.map(&Map.get(&1, assigns.metric, 0)) |> Enum.sum()
      end

    assigns = assign(assigns, :max, Enum.max([1.0e-9 | totals]))

    ~H"""
    <div class="flex h-44 items-end gap-1">
      <div
        :for={{date, by_agent} <- Enum.sort(@days)}
        class="group relative flex h-full flex-1 flex-col-reverse"
        title={"#{date}: #{@format.(day_total(by_agent, @metric))}"}
      >
        <div class="mt-auto"></div>
        <div
          :for={{agent, values} <- Enum.sort(by_agent)}
          style={"height: #{percent(Map.get(values, @metric, 0), @max)}%; background: #{color_for(agent, @agents)}"}
          class="w-full min-h-0"
          title={"#{date} #{agent}: #{@format.(Map.get(values, @metric, 0))}"}
        >
        </div>
        <span class="absolute -bottom-5 left-0 right-0 truncate text-center text-[9px] text-base-content/40">
          {String.slice(date, 8, 2)}
        </span>
      </div>
    </div>
    <div class="h-5"></div>
    """
  end

  attr(:agents, :list, required: true)

  @doc "The shared agent color legend."
  def legend(assigns) do
    ~H"""
    <div class="mt-2 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
      <span :for={agent <- @agents} class="flex items-center gap-1">
        <span class="inline-block h-2 w-2 rounded-sm" style={"background: #{color_for(agent, @agents)}"}>
        </span>
        {agent}
      </span>
    </div>
    """
  end

  attr(:gates, :list, required: true)
  attr(:median, :integer, required: true)

  @doc "Gate latency as labeled horizontal CSS bars, newest first."
  def gate_latency(assigns) do
    assigns = assign(assigns, :max, Enum.max([1 | Enum.map(assigns.gates, & &1.minutes)]))

    ~H"""
    <p class="mb-2 text-xs text-base-content/50">
      median wait <b>{@median}m</b> over the last {length(@gates)} gates
    </p>
    <div :for={gate <- @gates} class="mb-1 text-xs">
      <div class="flex items-baseline justify-between gap-2">
        <span class="truncate text-base-content/70">
          <b class="font-mono">{gate.agent}</b> {gate.detail}
        </span>
        <span class="shrink-0 font-mono text-base-content/50">{gate.minutes}m</span>
      </div>
      <div class="h-1.5 rounded bg-base-300">
        <div
          class={["h-1.5 rounded", (gate.status == "resolved" && "bg-success") || "bg-warning"]}
          style={"width: #{percent(gate.minutes, @max)}%"}
        >
        </div>
      </div>
    </div>
    <p :if={@gates == []} class="text-sm text-base-content/40">(no resolved gates yet)</p>
    """
  end

  attr(:values, :list, required: true)
  attr(:class, :string, default: "h-6 w-24")

  @doc "A tiny SVG polyline sparkline (stroke follows text color)."
  def sparkline(assigns) do
    values = assigns.values
    max = Enum.max([1.0e-9 | values])
    n = max(length(values) - 1, 1)

    points =
      values
      |> Enum.with_index()
      |> Enum.map_join(" ", fn {value, index} ->
        x = Float.round(index * 100 / n, 1)
        y = Float.round(28 - value / max * 26, 1)
        "#{x},#{y}"
      end)

    assigns = assign(assigns, :points, points)

    ~H"""
    <svg viewBox="0 0 100 30" preserveAspectRatio="none" class={@class}>
      <polyline
        points={@points}
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        vector-effect="non-scaling-stroke"
      />
    </svg>
    """
  end

  defp day_total(by_agent, metric) do
    by_agent |> Map.values() |> Enum.map(&Map.get(&1, metric, 0)) |> Enum.sum()
  end

  defp percent(value, max) when max > 0, do: Float.round(value / max * 100, 2)
  defp percent(_value, _max), do: 0.0
end
