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
          <span class="font-mono text-xs text-base-content/60">
            {String.slice(@entry["at"] || "", 11, 8)}
            <span :if={@show_agent}>{@entry["agent"]}</span>
          </span>
          <span :if={@entry["cost_usd"]} class="ml-auto font-mono text-xs">
            ${usd(@entry["cost_usd"])}<span :if={@entry["tokens"]} class="text-base-content/50"> &middot; {tok(@entry["tokens"])}</span>
          </span>
        </div>
        <p class="text-base-content/80">{feed_text(@entry)}</p>
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

  @doc "Dollar amounts render with two decimals everywhere (#31)."
  def usd(value) when is_number(value), do: :erlang.float_to_binary(value / 1, decimals: 2)

  @doc "Token counts render compact: 900, 45k, 2.4M (#30)."
  def tok(count) when count >= 1_000_000, do: "#{Float.round(count / 1_000_000, 1)}M tok"
  def tok(count) when count >= 1_000, do: "#{round(count / 1_000)}k tok"
  def tok(count) when is_integer(count), do: "#{count} tok"

  @doc """
  The text of a feed card. Failure events carry a what-happens-next hint --
  a bare rail kind ("max_turns_exceeded") tells the operator what broke but
  not whether anyone has to do anything (#31).
  """
  def feed_text(%{"event" => "turn_failed"} = entry),
    do: "#{entry["kind"]} -- #{failure_hint(entry["kind"])}"

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
