defmodule CustodeWeb.Console.Header do
  @moduledoc """
  The console's header (#450): where the operator is, a sentence to the
  caretaker from anywhere (#451), what needs them, presence, the fleet-wide
  controls, and how much of the plan is used (#458).
  """

  use Phoenix.Component

  import CustodeWeb.Components, only: [theme_toggle: 1, usd: 1]

  attr(:caretaker, :any, required: true)
  attr(:tell_gen, :integer, required: true)
  attr(:needs_you, :integer, required: true)
  attr(:presence, :any, required: true)
  attr(:usage, :map, required: true)
  attr(:fleet_today, :any, required: true)
  attr(:notice, :string, default: nil)

  def console_header(assigns) do
    ~H"""
    <header class="flex items-baseline gap-4 border-b border-base-300 bg-base-100 px-5 py-3">
      <.link navigate="/" class="text-xl font-bold hover:opacity-70">custode</.link>
      <nav class="flex gap-3 text-sm text-base-content/60">
        <span class="font-semibold text-base-content underline underline-offset-4">console</span>
        <.link navigate="/custode" class="hover:text-base-content" title="Cmd/Ctrl+K">
          custode
        </.link>
        <.link navigate="/fleet" class="hover:text-base-content">fleet</.link>
        <.link navigate="/inbox" class="hover:text-base-content">inbox</.link>
        <.link navigate="/repos" class="hover:text-base-content">repos</.link>
        <.link navigate="/workflows" class="hover:text-base-content">workflows</.link>
        <.link navigate="/metrics" class="hover:text-base-content">metrics</.link>
      </nav>
      <%!-- Most of what the operator wants is a sentence to the caretaker,
            not a visit to one agent (#451). --%>
      <form
        :if={@caretaker}
        id={"tell-#{@tell_gen}"}
        phx-submit="tell_custode"
        class="ml-auto flex min-w-0 flex-1 justify-end"
      >
        <input
          type="text"
          name="text"
          autocomplete="off"
          placeholder={"tell #{@caretaker}..."}
          class="input input-bordered input-sm w-full max-w-md"
        />
      </form>
      <span :if={@needs_you > 0} class={["badge badge-warning whitespace-nowrap", !@caretaker && "ml-auto"]}>
        {@needs_you} need you
      </span>
      <button
        class={[
          "badge cursor-pointer whitespace-nowrap",
          (match?({:away, _}, @presence) && "badge-neutral") || "badge-ghost",
          !@caretaker && @needs_you == 0 && "ml-auto"
        ]}
        phx-click="toggle_presence"
        title="present: gates ping you. away: pinned, the desktop stays quiet and the phone still rings"
      >
        {presence_word(@presence)}
      </button>
      <.theme_toggle />
      <details class="dropdown dropdown-end">
        <summary class="btn btn-ghost btn-xs">fleet</summary>
        <ul class="menu dropdown-content z-10 mt-1 w-44 rounded-box bg-base-100 p-2 shadow-lg">
          <li>
            <button phx-click="pause_all" data-confirm="Pause every running agent?">
              pause all
            </button>
          </li>
          <li><button phx-click="resume_all">resume all</button></li>
          <li>
            <button
              phx-click="drain"
              data-confirm="Drain for a restart? Queues pause, executing turns finish, then the node STOPS and this page goes away."
            >
              drain for restart
            </button>
          </li>
        </ul>
      </details>
      <.usage usage={@usage} />
      <span class="whitespace-nowrap font-mono text-xs text-base-content/40">
        ${usd(@fleet_today)}
      </span>
    </header>
    <p :if={@notice} class="bg-base-100 px-5 pb-2 text-right text-xs text-base-content/60">
      {@notice}
    </p>
    """
  end

  attr(:usage, :map, required: true)

  # How much of the plan's windows is used (#458). On a Max plan this is the
  # number that decides whether the fleet can keep working; dollars are
  # accounting. Unknown draws NOTHING: an empty header is honest and "0%" is
  # not. Stale is dimmed and says so, unless a rejecting window's reset is
  # still ahead (#525): that limit holds whatever the reading's age, so it is
  # drawn at full strength with the instant it is held until.
  defp usage(assigns) do
    ~H"""
    <span
      :if={@usage.freshness != :unknown and @usage.windows != []}
      class={[
        "flex items-baseline gap-2 whitespace-nowrap font-mono text-sm",
        @usage.freshness == :stale && !@usage.held_until && "opacity-50"
      ]}
      title={usage_title(@usage)}
    >
      <span :for={window <- @usage.windows} class={usage_tone(window)}>
        {window.label} {percent(window.utilization)}
      </span>
      <span :if={@usage.held_until} class="text-xs font-bold text-error">
        held until {clock(@usage.held_until)}
      </span>
      <span :if={@usage.freshness == :stale and !@usage.held_until} class="text-xs text-base-content/50">
        stale
      </span>
    </span>
    """
  end

  defp percent(nil), do: "?"
  defp percent(utilization), do: "#{round(utilization * 100)}%"

  # one meaning per color (guides/ui-hierarchy.md): red is blocked, yellow
  # wants you, grey is ambient
  defp usage_tone(%{status: :rejected}), do: "font-bold text-error"

  defp usage_tone(%{utilization: used}) when is_number(used) and used >= 0.95,
    do: "font-bold text-error"

  defp usage_tone(%{status: :warning}), do: "text-warning"
  defp usage_tone(%{utilization: used}) when is_number(used) and used >= 0.8, do: "text-warning"
  defp usage_tone(_window), do: "text-base-content/70"

  defp usage_title(%{windows: windows, observed_at: observed_at} = usage) do
    resets =
      Enum.map_join(windows, "; ", fn window ->
        "#{window.label} resets #{reset_words(window.resets_at)}"
      end)

    "claude plan usage. #{resets}. Observed #{reset_words(observed_at)}." <> held_words(usage)
  end

  defp held_words(%{held_until: %DateTime{} = until, age_seconds: age}),
    do: " Limited until #{clock(until)} UTC (from a reading #{age_words(age)} old)."

  defp held_words(_usage), do: ""

  defp clock(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M")

  defp age_words(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp age_words(seconds), do: "#{div(seconds, 3600)}h#{rem(div(seconds, 60), 60)}m"

  defp reset_words(nil), do: "at an unknown time"
  defp reset_words(%DateTime{} = at), do: Calendar.strftime(at, "%a %H:%M UTC")

  defp presence_word({:present, _at}), do: "present"
  defp presence_word({:away, _at}), do: "away"
end
