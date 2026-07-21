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
            ${@entry["cost_usd"]}
          </span>
        </div>
        <p class="text-base-content/80">
          {@entry["summary"] || @entry["action"] || @entry["question"] || @entry["kind"]}
        </p>
      </div>
    </div>
    """
  end

  slot(:inner_block, required: true)
  attr(:fleet_today, :float, required: true)
  attr(:active, :atom, default: :fleet)

  @doc "The shared page chrome: header with nav and the fleet spend."
  def page(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <header class="mb-6 flex items-baseline gap-4">
        <.link navigate="/" class="text-3xl font-bold hover:opacity-70">custode</.link>
        <nav class="flex gap-3 text-sm">
          <.link navigate="/" class={nav_class(@active == :fleet)}>fleet</.link>
          <.link navigate="/feed" class={nav_class(@active == :feed)}>feed</.link>
        </nav>
        <span class="ml-auto font-mono text-sm text-base-content/70">
          fleet today ${Float.round(@fleet_today, 4)}
        </span>
      </header>
      {render_slot(@inner_block)}
    </div>
    """
  end

  defp nav_class(true), do: "font-semibold underline underline-offset-4"
  defp nav_class(false), do: "text-base-content/60 hover:text-base-content"
end
