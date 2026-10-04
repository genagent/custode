defmodule CustodeWeb.DigestPanel do
  @moduledoc "A shared, compact view of the typed fleet digest."

  use Phoenix.Component

  import CustodeWeb.Components, only: [ago_text: 1, markdown: 1, tok: 1, usd: 1]

  attr(:id, :string, required: true)
  attr(:digest, :map, required: true)

  def digest_panel(assigns) do
    spenders =
      Enum.sort_by(assigns.digest.spend.by_agent, fn {agent, row} -> {-row.usd, agent} end)

    {top_spenders, remaining_spenders} = Enum.split(spenders, 5)

    assigns =
      assigns
      |> assign(:top_spenders, top_spenders)
      |> assign(:remaining_spenders, remaining_spenders)
      |> assign(
        :max_spend,
        spenders |> Enum.map(fn {_agent, row} -> row.usd end) |> Enum.max(fn -> 0 end)
      )
      |> assign(:show_spend, spend?(assigns.digest.spend))
      |> assign(:show_details, details?(assigns.digest))
      |> assign(
        :failure_kinds,
        Enum.sort_by(assigns.digest.failures.by_kind, fn {kind, count} -> {-count, kind} end)
      )
      |> assign(
        :models,
        Enum.sort_by(assigns.digest.spend.by_model, fn {model, row} -> {-row.usd, model} end)
      )

    ~H"""
    <section id={@id} data-digest-panel class="min-w-0 text-sm">
      <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <h3 class="font-semibold">Fleet digest</h3>
        <span class="text-xs text-base-content/60" title={window_title(@digest)}>
          {window_label(@digest)}
        </span>
        <p data-digest-lead class="text-base-content/80">{lead(@digest)}</p>
      </div>

      <details :if={@show_details} id={@id <> "-details"} data-digest-details class="mt-3">
        <summary class="cursor-pointer text-xs text-base-content/60 hover:text-base-content">
          View details
        </summary>
        <div class="mt-4 space-y-5 border-t border-base-300 pt-4">
          <section :if={@digest.anomalies != []} data-digest-section="anomalies">
            <h4 class="mb-2 font-semibold">Recorded anomalies</h4>
            <ul class="space-y-2 break-words">
              <li :for={anomaly <- @digest.anomalies}>
                <.markdown text={anomaly} />
              </li>
            </ul>
          </section>

          <section
            :if={@digest.failures.total > 0 or @failure_kinds != []}
            data-digest-section="failures"
          >
            <h4 class="font-semibold">Failed turns</h4>
            <p class="mt-1 text-xs text-base-content/60">{@digest.failures.total} in this window</p>
            <dl class="mt-2 space-y-1">
              <div :for={{kind, count} <- @failure_kinds} class="flex justify-between gap-4">
                <dt class="break-words font-mono text-xs">{kind}</dt>
                <dd class="shrink-0 font-mono text-xs">{count}</dd>
              </div>
            </dl>
          </section>

          <section :if={@digest.gates.count > 0} data-digest-section="gates">
            <h4 class="font-semibold">Recent gate sample</h4>
            <p class="mt-1 text-xs text-base-content/60">
              {@digest.gates.count} recent resolutions shown &middot;
              median {@digest.gates.median_minutes} min to resolution
            </p>
            <ul class="mt-2 space-y-3">
              <li :for={gate <- @digest.gates.recent} class="break-words">
                <div class="mb-1 flex flex-wrap gap-x-2 text-xs text-base-content/60">
                  <span class="font-mono">{gate.agent}</span>
                  <span>{gate.status}</span>
                  <span>{gate.minutes} min</span>
                </div>
                <.markdown text={gate.detail} />
              </li>
            </ul>
          </section>

          <section :if={@digest.suggestions != []} data-digest-section="suggestions">
            <h4 class="font-semibold">Suggestion history</h4>
            <p class="mt-1 text-xs text-base-content/60">
              Latest records; may predate this window or already have been acted on.
            </p>
            <ul class="mt-2 space-y-3">
              <li :for={suggestion <- @digest.suggestions} class="break-words">
                <div class="mb-1 flex flex-wrap gap-x-2 text-xs text-base-content/60">
                  <span class="font-mono">{suggestion.advisor} &rarr; {suggestion.agent}</span>
                  <span :if={suggestion.confidence}>{suggestion.confidence} confidence</span>
                </div>
                <p>
                  <span class="font-mono">{suggestion.field}</span>:
                  <code>{value_text(suggestion.current)}</code> &rarr;
                  <code>{value_text(suggestion.proposed)}</code>
                </p>
                <.markdown :if={suggestion.evidence} text={value_text(suggestion.evidence)} />
              </li>
            </ul>
          </section>

          <section :if={@show_spend} data-digest-section="spend" class="text-base-content/70">
            <h4 class="font-semibold">Recorded spend</h4>
            <p class="mt-1 font-mono text-xs">
              ${usd(@digest.spend.total_usd)} &middot; {tok(@digest.spend.total_tokens)}
            </p>

            <div :if={@top_spenders != []} class="mt-3">
              <h5 class="mb-2 text-xs">Highest spend by agent</h5>
              <ol data-digest-top-spenders class="space-y-3">
                <li :for={{agent, row} <- @top_spenders} data-digest-spender={agent}>
                  <div class="mb-1 flex flex-wrap justify-between gap-x-4 gap-y-1 font-mono text-xs">
                    <span class="min-w-0 break-all">{agent}</span>
                    <span>${usd(row.usd)} &middot; {tok(row.tokens)}</span>
                  </div>
                  <div aria-hidden="true" class="h-1.5 overflow-hidden rounded-full bg-base-300">
                    <div class="h-full bg-base-content/40" style={"width: #{spend_width(row.usd, @max_spend)}%"}>
                    </div>
                  </div>
                </li>
              </ol>
            </div>

            <details
              :if={@remaining_spenders != []}
              id={@id <> "-remaining-agents"}
              data-digest-remaining-spenders
              class="mt-3"
            >
              <summary class="cursor-pointer text-xs">
                {length(@remaining_spenders)} more {agent_word(length(@remaining_spenders))}
              </summary>
              <dl class="mt-2 space-y-2">
                <div
                  :for={{agent, row} <- @remaining_spenders}
                  data-digest-spender={agent}
                  class="flex flex-wrap justify-between gap-x-4 gap-y-1 font-mono text-xs"
                >
                  <dt class="min-w-0 break-all">{agent}</dt>
                  <dd>${usd(row.usd)} &middot; {tok(row.tokens)}</dd>
                </div>
              </dl>
            </details>

            <div :if={@models != []} class="mt-4 overflow-x-auto">
              <table class="table table-xs">
                <caption class="mb-1 text-left text-xs">By model</caption>
                <thead>
                  <tr>
                    <th scope="col">Model</th>
                    <th scope="col" class="text-right">Turns</th>
                    <th scope="col" class="text-right">Failed</th>
                    <th scope="col" class="text-right">Spend</th>
                    <th scope="col" class="text-right">Tokens</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{model, row} <- @models}>
                    <th scope="row" class="break-words font-mono font-normal">{model}</th>
                    <td class="text-right">{row.turns}</td>
                    <td class="text-right">{row.failed}</td>
                    <td class="text-right font-mono">${usd(row.usd)}</td>
                    <td class="text-right font-mono">{tok(row.tokens)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </section>
        </div>
      </details>
    </section>
    """
  end

  defp lead(digest), do: turn_summary(digest.sweeps) <> anomaly_summary(digest.anomalies)

  defp turn_summary(%{total: 0}), do: "No turns recorded in this window."

  defp turn_summary(sweeps) do
    "#{sweeps.ok} of #{sweeps.total} recorded #{turn_word(sweeps.total)} succeeded " <>
      "(#{sweeps.yield_pct}%); #{sweeps.failed} failed."
  end

  defp anomaly_summary([]), do: ""
  defp anomaly_summary([_anomaly]), do: " 1 anomaly recorded."
  defp anomaly_summary(anomalies), do: " #{length(anomalies)} anomalies recorded."

  defp agent_word(1), do: "agent"
  defp agent_word(_count), do: "agents"

  defp turn_word(1), do: "turn"
  defp turn_word(_count), do: "turns"

  defp window_label(%{window_days: 1}), do: "last 1 day"
  defp window_label(%{window_days: days}), do: "last #{days} days"
  defp window_label(%{since: since}), do: "since #{ago_text(since)}"

  defp window_title(%{since: since}), do: DateTime.to_iso8601(since)
  defp window_title(_digest), do: nil

  defp details?(digest) do
    digest.anomalies != [] or digest.failures.total > 0 or
      map_size(digest.failures.by_kind) > 0 or digest.gates.count > 0 or
      digest.suggestions != [] or spend?(digest.spend)
  end

  defp spend?(spend) do
    spend.total_usd > 0 or spend.total_tokens > 0 or
      map_size(spend.by_agent) > 0 or map_size(spend.by_model) > 0
  end

  defp spend_width(_usd, max) when max <= 0, do: 0
  defp spend_width(usd, max), do: Float.round(usd / max * 100, 2)

  defp value_text(nil), do: "(none)"
  defp value_text(value) when is_binary(value), do: value
  defp value_text(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)
end
