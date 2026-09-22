defmodule CustodeWeb.Console.Rail do
  @moduledoc """
  The console's rail (#450): every subject, grouped by what it needs. The
  grouping and the order are `Custode.Attention.Fleet`'s and nothing else;
  this module only draws them (design/007).

  The entries are what the operator comes back to, which design/010 calls
  topics. Today a topic is a routine, one per repository.
  """

  use Phoenix.Component

  alias Custode.Signal
  alias CustodeWeb.Components

  @group_titles %{
    needs_you: "needs you",
    watching: "watching",
    working: "working",
    scheduled: "scheduled",
    quiet: "quiet"
  }

  attr(:groups, :list, required: true)
  attr(:selected, :string, default: nil)
  attr(:filter, :string, required: true)
  attr(:in_flight, :map, required: true)

  def rail(assigns) do
    ~H"""
    <nav id="subject-rail" class="bg-base-100 p-4" aria-label="subjects" phx-hook="SubjectRail">
      <form id="rail-filter" phx-change="filter" phx-submit="filter" class="mb-4">
        <input
          type="search"
          name="q"
          value={@filter}
          placeholder="filter: name, repo, tag, state"
          autocomplete="off"
          phx-debounce="150"
          class="input input-bordered input-sm w-full"
        />
      </form>

      <p :if={@groups == []} class="text-sm text-base-content/50">nothing matches</p>
      <button class="btn btn-outline btn-xs mb-4 w-full" phx-click="new_open">new agent</button>

      <section :for={{group, signals} <- @groups} class="mb-5">
        <h2 class={["mb-1 text-xs font-bold uppercase tracking-widest", group_tone(group)]}>
          {group_title(group)}
          <span class="font-normal text-base-content/40">{length(signals)}</span>
        </h2>
        <ul>
          <li :for={signal <- signals}>
            <.link
              patch={subject_path(signal.subject)}
              data-rail-subject
              aria-current={signal.subject == @selected && "page"}
              class={[
                "flex items-center gap-2 rounded px-2 py-1.5 font-mono text-sm hover:bg-base-200",
                signal.subject == @selected && "bg-base-200 font-bold",
                group in [:scheduled, :quiet] && "text-base-content/60"
              ]}
            >
              <span class={["inline-block size-2 shrink-0 rounded-full", dot(signal)]}></span>
              <span class="min-w-0 flex-1">
                <span class="block truncate">{signal.subject}</span>
                <%!-- Seeing many things at once is the point: a rail of bare
                      names made every one of them a click. Only the groups
                      that mean something is wrong pay the second line. --%>
                <span
                  :if={group in [:needs_you, :watching]}
                  class="block truncate font-sans text-xs font-normal text-base-content/60"
                >
                  {signal.headline}
                </span>
              </span>
              <span class="ml-auto shrink-0 self-start text-xs font-normal text-base-content/50">
                {rail_note(signal, @in_flight)}
              </span>
            </.link>
          </li>
        </ul>
      </section>
    </nav>
    """
  end

  # An agent id is a slug and passes through unchanged. A workflow signal's
  # subject is "<workflow> on <owner>/<repo>" (#447), and an unencoded slash
  # there would be a second path segment and no route.
  def subject_path(subject), do: "/console/" <> URI.encode(subject, &URI.char_unreserved?/1)

  defp group_title(group), do: Map.fetch!(@group_titles, group)

  defp group_tone(:needs_you), do: "text-warning"
  defp group_tone(:watching), do: "text-warning/70"
  defp group_tone(:working), do: "text-info"
  defp group_tone(_group), do: "text-base-content/50"

  # One meaning per color (guides/ui-hierarchy.md): red is blocked on you,
  # yellow wants you, blue is working, grey is ambient.
  defp dot(%Signal{kind: kind})
       when kind in [:red_main, :turn_failing, :rail_hit, :disowned_check],
       do: "bg-error"

  defp dot(%Signal{group: :needs_you}), do: "bg-warning"
  defp dot(%Signal{group: :watching}), do: "bg-warning/60"
  defp dot(%Signal{group: :working}), do: "bg-info animate-pulse"
  defp dot(%Signal{group: :scheduled}), do: "bg-base-content/30"
  defp dot(%Signal{}), do: "bg-base-content/15"

  defp rail_note(%Signal{group: :working, subject: id}, in_flight) do
    case Map.get(in_flight, id) do
      %DateTime{} = started -> elapsed(DateTime.diff(DateTime.utc_now(), started, :second))
      _none -> ""
    end
  end

  defp rail_note(%Signal{kind: :scheduled, item: {:next_beat, at}}, _in_flight),
    do: Components.until_text(at)

  defp rail_note(%Signal{kind: :approval}, _in_flight), do: "gate"
  defp rail_note(%Signal{kind: :needs_answer}, _in_flight), do: "asked"
  defp rail_note(%Signal{kind: :rail_hit}, _in_flight), do: "rail"
  defp rail_note(%Signal{kind: :paused}, _in_flight), do: "paused"
  defp rail_note(%Signal{}, _in_flight), do: ""

  defp elapsed(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m"
  defp elapsed(seconds), do: "#{max(seconds, 0)}s"
end
