defmodule CustodeWeb.Charts do
  @moduledoc """
  Dependency-free charts for the metrics page: daily CSS stacks with a
  shared baseline and exact-value table, horizontal gate-latency bars, and
  small SVG sparklines. Semantic colors follow the active theme.
  """

  use Phoenix.Component

  # Series identities and order come from the read model. These semantic
  # colors follow both themes; exact values never depend on color alone.
  @series_tones ~w(bg-primary bg-secondary bg-info bg-success bg-neutral)

  attr(:id, :string, required: true)
  attr(:chart, :map, required: true)
  attr(:label, :string, required: true)
  attr(:format, :any, required: true)
  attr(:exact_format, :any, required: true)

  @doc """
  A prepared daily chart: one scale, ordered stacks and legend, and exact
  values in a native disclosure. The caller owns aggregation and ranking.
  """
  def daily_chart(assigns) do
    assigns = assign(assigns, :series, indexed_series(assigns.chart.series))

    ~H"""
    <figure id={@id} aria-labelledby={@id <> "-caption"} class="min-w-0">
      <figcaption id={@id <> "-caption"} class="mb-3 flex flex-wrap gap-x-3 gap-y-1 text-xs text-base-content/60">
        <span class="sr-only">{@label}.</span>
        <span>↑ Today: <time datetime={@chart.today}>{@chart.today}</time> (UTC)</span>
        <span class="ml-auto" title={@exact_format.(@chart.total)}>Total: {@format.(@chart.total)}</span>
      </figcaption>
      <div class="flex min-w-0">
        <div class="relative h-44 w-16 shrink-0 font-mono text-[10px] text-base-content/60" aria-label="Chart scale">
          <span data-chart-max class="absolute left-0 right-2 top-0 break-words text-right [overflow-wrap:anywhere]" title={@exact_format.(@chart.max)}>
            Max {@format.(@chart.max)}
          </span>
          <span data-chart-baseline class="absolute bottom-0 right-2" title={@exact_format.(0)}>
            {@format.(0)}
          </span>
        </div>
        <div class="min-w-0 flex-1">
          <div data-chart-plot class="flex h-44 items-end gap-1 border-b border-base-content/40">
            <div
              :for={day <- @chart.days}
              data-chart-day={day.date}
              data-chart-today={to_string(day.date == @chart.today)}
              data-chart-total={day.total}
              role="img"
              aria-label={day_description(day, @chart.series, @chart.today, @exact_format)}
              title={day_description(day, @chart.series, @chart.today, @exact_format)}
              class="relative flex h-full min-w-0 flex-1 flex-col-reverse"
            >
              <div
                :for={{series, index} <- @series}
                :if={value(day, series) > 0}
                data-chart-series={series.label}
                data-chart-value={value(day, series)}
                class={["w-full shrink-0", series_tone(series, index)]}
                style={"height: #{percent(value(day, series), @chart.max)}%"}
                title={"#{day.date} #{series.label}: #{@exact_format.(value(day, series))}"}
              >
              </div>
              <span
                :if={day.total == 0}
                data-chart-zero
                aria-hidden="true"
                class="absolute bottom-0 h-0.5 w-full bg-base-content/40"
              >
              </span>
            </div>
          </div>
          <div class="mt-1 flex gap-1 text-center font-mono text-[9px] text-base-content/70">
            <span
              :for={day <- @chart.days}
              data-chart-date={day.date}
              class={["min-w-0 flex-1", day.date == @chart.today && "font-bold underline decoration-2 underline-offset-2"]}
              title={if day.date == @chart.today, do: "#{day.date} (Today)", else: day.date}
            >
              <span :if={day.date == @chart.today} aria-hidden="true">↑</span>{String.slice(day.date, 8, 2)}
            </span>
          </div>
        </div>
      </div>
      <p :if={@chart.total == 0} class="mt-3 text-xs text-base-content/60">No recorded value in this period.</p>
      <ul id={@id <> "-legend"} aria-label={@label <> " series totals"} class="mt-3 flex flex-wrap gap-x-4 gap-y-2 text-xs text-base-content/70">
        <li :for={{series, index} <- @series} class="flex min-w-0 max-w-full items-start gap-1.5" title={@exact_format.(series.total)}>
          <span aria-hidden="true" class={["mt-1 inline-block size-2 shrink-0 rounded-sm", series_tone(series, index)]}></span>
          <span class="min-w-0 break-words [overflow-wrap:anywhere]">{series.label}: <span class="font-mono">{@format.(series.total)}</span></span>
        </li>
      </ul>
      <details id={@id <> "-values-disclosure"} class="mt-3">
        <summary class="link cursor-pointer text-xs text-base-content/70">Exact daily values</summary>
        <div
          role="region"
          aria-label={@label <> " exact daily values"}
          tabindex="0"
          class="mt-2 max-w-full overflow-x-auto rounded focus-visible:outline focus-visible:outline-2"
        >
          <table id={@id <> "-values"} class="table table-xs w-full">
            <caption class="sr-only">{@label}, exact values by UTC date</caption>
            <thead>
              <tr>
                <th scope="col">Date (UTC)</th>
                <th :for={series <- @chart.series} scope="col" class="max-w-40 whitespace-normal break-words text-right [overflow-wrap:anywhere]">{series.label}</th>
                <th scope="col" class="text-right">Total</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={day <- @chart.days}>
                <th scope="row" class="whitespace-nowrap font-normal">
                  {day.date}<span :if={day.date == @chart.today} class="ml-1 font-semibold">Today</span>
                </th>
                <td :for={series <- @chart.series} class="whitespace-nowrap text-right font-mono">{@exact_format.(value(day, series))}</td>
                <td class="whitespace-nowrap text-right font-mono">{@exact_format.(day.total)}</td>
              </tr>
            </tbody>
          </table>
        </div>
      </details>
    </figure>
    """
  end

  attr(:gates, :list, required: true)
  attr(:median, :integer, required: true)

  @doc "Gate latency as labeled horizontal CSS bars, newest first."
  def gate_latency(assigns) do
    assigns = assign(assigns, :max, Enum.max([1 | Enum.map(assigns.gates, & &1.minutes)]))

    ~H"""
    <p class="mb-2 text-xs text-base-content/50">
      median wait <b>{@median}m</b> over the last {length(@gates)} {if length(@gates) == 1, do: "gate", else: "gates"}
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

  defp value(day, series), do: Map.get(day.values, series.key, 0)

  defp day_description(day, series, today, format) do
    date = if day.date == today, do: "#{day.date} (Today)", else: day.date

    values =
      Enum.map_join(series, "; ", fn item ->
        "#{item.label}: #{format.(value(day, item))}"
      end)

    "#{date}: total #{format.(day.total)}" <> if(values == "", do: "", else: "; " <> values)
  end

  # Other owns its muted tone and must not consume a named contributor's
  # palette slot when its total places it in the middle of the ranking.
  defp indexed_series(series) do
    {indexed, _next} =
      Enum.map_reduce(series, 0, fn
        %{kind: :other} = item, index -> {{item, index}, index}
        item, index -> {{item, index}, index + 1}
      end)

    indexed
  end

  defp series_tone(%{kind: :other}, _index), do: "bg-base-content/30"
  defp series_tone(%{kind: :outcome, key: :ok}, _index), do: "bg-success"
  defp series_tone(%{kind: :outcome, key: :failed}, _index), do: "bg-error"
  defp series_tone(_series, index), do: Enum.at(@series_tones, rem(index, length(@series_tones)))

  defp percent(value, max) when max > 0, do: Float.round(value / max * 100, 2)
  defp percent(_value, _max), do: 0.0
end
