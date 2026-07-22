defmodule CustodeWeb.Components do
  @moduledoc """
  Shared function components and badge palettes for the dashboard pages.
  """

  use Phoenix.Component

  @doc "The lifecycle state badge class."
  def state_badge(:idle), do: "badge-ghost"
  def state_badge(:running), do: "badge-info"
  def state_badge(:awaiting_permission), do: "badge-warning"
  def state_badge(:waiting_for_user), do: "badge-accent"
  def state_badge(:paused), do: "badge-error"
  def state_badge(_state), do: "badge-outline"

  @doc "The feed event badge class."
  def feed_badge("turn"), do: "badge-info"
  def feed_badge("turn_failed"), do: "badge-error"
  def feed_badge("needs_approval"), do: "badge-warning"
  def feed_badge("needs_input"), do: "badge-accent"
  def feed_badge("budget_paused"), do: "badge-error"
  def feed_badge("doctor_failed"), do: "badge-error"
  def feed_badge(_event), do: "badge-ghost"

  attr(:entry, :map, required: true)
  attr(:show_agent, :boolean, default: true)

  @doc "One feed entry card (used by the feed page and the agent detail page)."
  def feed_entry(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow-sm">
      <div class="card-body p-3 text-sm">
        <div class="flex items-center gap-2">
          <span class={["badge badge-sm", feed_badge(@entry["event"])]}>{@entry["event"]}</span>
          <.resolved_chip entry={@entry} />
          <span class="font-mono text-xs text-base-content/60">
            <.ago at={@entry["at"]} />
            <.link
              :if={@show_agent && agent_linkable?(@entry["agent"])}
              navigate={"/agents/#{@entry["agent"]}"}
              class="link-hover hover:text-base-content"
            >
              {@entry["agent"]}
            </.link>
            <span :if={@show_agent && !agent_linkable?(@entry["agent"])}>{@entry["agent"]}</span>
          </span>
          <span :if={@entry["cost_usd"]} class="ml-auto font-mono text-xs">
            ${usd(@entry["cost_usd"])}<span :if={@entry["tokens"]} class="text-base-content/50"> &middot; {tok(@entry["tokens"])}</span>
          </span>
        </div>
        <p class="text-base-content/80">{feed_text(@entry)}</p>
        <.prompt_answer entry={@entry} />
      </div>
    </div>
    """
  end

  slot(:inner_block, required: true)
  attr(:fleet_today, :float, required: true)
  attr(:active, :atom, default: :fleet)

  @doc "The shared page chrome: header with nav, the attention chip, the fleet spend."
  def page(assigns) do
    assigns = assign(assigns, :attention, attention())

    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <header class="mb-6 flex items-baseline gap-4">
        <.link navigate="/" class="text-3xl font-bold hover:opacity-70">custode</.link>
        <nav class="flex gap-3 text-sm">
          <.link navigate="/" class={nav_class(@active == :fleet)}>fleet</.link>
          <.link navigate="/feed" class={nav_class(@active == :feed)}>feed</.link>
          <.link navigate="/metrics" class={nav_class(@active == :metrics)}>metrics</.link>
        </nav>
        <.link :if={@attention != []} navigate="/" class="badge badge-warning gap-1">
          {attention_text(@attention)}
        </.link>
        <span class="ml-auto font-mono text-sm text-base-content/70">
          fleet today ${usd(@fleet_today)}
        </span>
      </header>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp agent_linkable?(agent), do: is_binary(agent) and agent not in ["", "?"]

  attr(:entry, :map, required: true)

  @doc "The worked-it chip on gate cards: what happened, and how long it waited."
  def resolved_chip(assigns) do
    ~H"""
    <span
      :if={@entry["resolved"]}
      class={[
        "badge badge-xs gap-1",
        (@entry["resolved"] == "rejected" && "badge-ghost") || "badge-success badge-outline"
      ]}
      title={@entry["resolved_at"]}
    >
      {if @entry["resolved"] == "rejected", do: "✗", else: "✓"} {@entry["resolved"]}
      <span :if={wait_minutes(@entry)} class="opacity-60">after {wait_minutes(@entry)}m</span>
    </span>
    """
  end

  defp wait_minutes(%{"at" => at, "resolved_at" => resolved_at})
       when is_binary(at) and is_binary(resolved_at) do
    with {:ok, opened, _o1} <- DateTime.from_iso8601(at),
         {:ok, closed, _o2} <- DateTime.from_iso8601(resolved_at) do
      minutes = div(DateTime.diff(closed, opened), 60)
      if minutes > 0, do: minutes
    else
      _bad -> nil
    end
  end

  defp wait_minutes(_entry), do: nil

  @doc "Budget progress color: calm until 60%, warning to 90%, error past."
  def budget_progress_class(spend, budget) when is_number(spend) and is_number(budget) do
    cond do
      budget <= 0 -> "progress-success"
      spend / budget >= 0.9 -> "progress-error"
      spend / budget >= 0.6 -> "progress-warning"
      true -> "progress-success"
    end
  end

  @doc "The feed event dot color for timeline middles."
  def event_dot("turn"), do: "text-info"
  def event_dot("turn_failed"), do: "text-error"
  def event_dot("needs_approval"), do: "text-warning"
  def event_dot("needs_input"), do: "text-accent"
  def event_dot("budget_paused"), do: "text-error"
  def event_dot("doctor_failed"), do: "text-error"
  def event_dot("repo_verb"), do: "text-success"
  def event_dot(_event), do: "text-base-content/30"

  attr(:text, :string, required: true)

  @doc """
  Markdown for agent output (journal tables and friends). The input is
  HTML-escaped BEFORE Earmark, so any raw HTML an agent (or an injected
  note) emits is inert by construction -- only Earmark-generated markup
  renders. Falls back to pre-wrapped text if parsing fails.
  """
  def markdown(assigns) do
    ~H"""
    <div class="agent-md text-base-content/80">{render_markdown(@text)}</div>
    """
  end

  defp render_markdown(text) do
    escaped = text |> Plug.HTML.html_escape()

    case Earmark.as_html(escaped, breaks: true) do
      {:ok, html, _messages} -> Phoenix.HTML.raw(html)
      {:error, _html, _messages} -> text
    end
  end

  attr(:entry, :map, required: true)
  attr(:id, :string, default: nil)

  @doc "One daisyUI timeline item for the feed page (#31: right component)."
  def timeline_item(assigns) do
    ~H"""
    <li id={@id}>
      <hr />
      <div class="timeline-start pr-2 text-right font-mono text-xs text-base-content/50">
        <.ago at={@entry["at"]} />
        <div>
          <.link
            :if={agent_linkable?(@entry["agent"])}
            navigate={"/agents/#{@entry["agent"]}"}
            class="link-hover"
          >
            {@entry["agent"]}
          </.link>
        </div>
      </div>
      <div class="timeline-middle">
        <svg viewBox="0 0 16 16" class={["h-3 w-3", event_dot(@entry["event"])]}>
          <circle cx="8" cy="8" r="6" fill="currentColor" />
        </svg>
      </div>
      <div class="timeline-end timeline-box mb-2 w-full bg-base-100 text-sm">
        <div class="mb-1 flex items-center gap-2">
          <span class={["badge badge-xs", feed_badge(@entry["event"])]}>{@entry["event"]}</span>
          <.resolved_chip entry={@entry} />
          <span :if={@entry["cost_usd"]} class="ml-auto font-mono text-xs text-base-content/50">
            ${usd(@entry["cost_usd"])}<span :if={@entry["tokens"]}> &middot; {tok(@entry["tokens"])}</span>
          </span>
        </div>
        <p class="whitespace-pre-wrap text-base-content/80">{feed_text(@entry)}</p>
        <.prompt_answer entry={@entry} />
      </div>
      <hr />
    </li>
    """
  end

  attr(:entry, :map, required: true)

  @doc """
  The durable answer to an operator prompt (#138). Operator-origin turns
  carry the full response on the feed entry; sweeps stay summary-only.
  Rendered expanded -- the operator asked, so the answer leads.
  """
  def prompt_answer(assigns) do
    ~H"""
    <div
      :if={@entry["response"]}
      class="agent-md mt-2 rounded border-l-2 border-primary/40 bg-base-200/60 p-2 text-sm"
    >
      <.markdown text={@entry["response"]} />
    </div>
    """
  end

  @doc "Dollar amounts render with two decimals everywhere (#31)."
  def usd(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @doc """
  Relative time for feed/journal stamps (#31): "4m ago" reads at a glance
  where "20:15:01" (UTC, while the operator lives in local time) does not.
  The absolute stamp stays available on hover via the title attribute.
  """
  attr(:at, :any, required: true)

  def ago(assigns) do
    ~H"""
    <span title={@at}>{ago_text(@at)}</span>
    """
  end

  @doc false
  def ago_text(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 0 -> "now"
      seconds < 60 -> "#{seconds}s ago"
      seconds < 3_600 -> "#{div(seconds, 60)}m ago"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h ago"
      true -> "#{div(seconds, 86_400)}d ago"
    end
  end

  def ago_text(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, parsed, _offset} -> ago_text(parsed)
      {:error, _reason} -> at
    end
  end

  def ago_text(_other), do: "?"

  @doc "Token counts render compact: 900, 45k, 2.4M (#30)."
  def tok(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M tok"
  def tok(count) when count >= 1_000, do: "#{round(count / 1_000)}k tok"
  def tok(count) when is_integer(count), do: "#{count} tok"

  @doc """
  The text of a feed card. Failure events carry a what-happens-next hint --
  a bare rail kind ("max_turns_exceeded") tells the operator what broke but
  not whether anyone has to do anything (#31).
  """
  def feed_text(%{"event" => "turn_failed"} = entry) do
    base = "#{entry["kind"]} -- #{failure_hint(entry["kind"])}"

    case entry["detail"] do
      detail when is_binary(detail) and detail != "" -> base <> "\n" <> detail
      _absent -> base
    end
  end

  def feed_text(%{"event" => "budget_paused"}),
    do: "daily budget rail crossed; auto-paused until a human resumes"

  def feed_text(entry),
    do: entry["summary"] || entry["action"] || entry["question"] || entry["kind"]

  defp failure_hint("max_turns_exceeded"),
    do:
      "turn cap hit mid-run; if this was an approval it re-gated, and re-approving grants a fresh turn budget"

  defp failure_hint("max_budget_exceeded"),
    do: "per-turn cost cap hit; a re-approval retries, or raise the routine's max_budget_usd"

  defp failure_hint("timeout"),
    do: "subprocess time cap hit; a re-approval retries, or raise the routine's timeout_ms"

  defp failure_hint(_kind),
    do: "the next beat retries; check the machine log if it repeats"

  @attention_states [:awaiting_permission, :waiting_for_user, :paused]

  @doc "Does this status (atom or gated tuple) need a human?"
  def needs_attention?({state, _payload}), do: state in @attention_states
  def needs_attention?(state), do: state in @attention_states

  defp attention do
    for {id, status} <- ObanClaude.Agent.list(), needs_attention?(status) do
      {id, status |> state_of() |> attention_word()}
    end
  end

  # "custode paused" reads as the actual situation; a bare count reads as
  # "something somewhere" and goes stale in the operator's head the moment
  # they resolve any one thing. Name the subjects while the list is short.
  defp attention_text(attention) when length(attention) <= 2,
    do: Enum.map_join(attention, ", ", fn {id, word} -> "#{id} #{word}" end)

  defp attention_text(attention), do: "#{length(attention)} need attention"

  defp attention_word(:awaiting_permission), do: "wants approval"
  defp attention_word(:waiting_for_user), do: "asks"
  defp attention_word(:paused), do: "paused"

  defp state_of({state, _payload}), do: state
  defp state_of(state) when is_atom(state), do: state

  defp nav_class(true), do: "font-semibold underline underline-offset-4"
  defp nav_class(false), do: "text-base-content/60 hover:text-base-content"
end
