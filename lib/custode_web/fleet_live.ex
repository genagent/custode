defmodule CustodeWeb.FleetLive do
  @moduledoc """
  The fleet at a glance: one compact tile per agent (routines first, then any
  other running agents), each carrying its live status, spend, and last
  message, with the fastest actions inline (approve/reject a gate, beat an
  offline routine). Click through an agent's name for the full detail page.

  All reads go through the facade; all pushes arrive over
  `Custode.PubSubBridge` -- no polling anywhere.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  alias Custode.Routine
  alias ObanClaude.Agent

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, socket |> assign(tag_filter: nil) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("beat", %{"id" => id}, socket) do
    {:ok, _job} = Custode.beat(id)
    {:noreply, socket}
  end

  def handle_event("approve", %{"id" => id, "action" => action_id}, socket) do
    Agent.approve_action(id, action_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"id" => id, "action" => action_id}, socket) do
    Agent.reject_action(id, action_id, "rejected from dashboard")
    {:noreply, refresh(socket)}
  end

  def handle_event("pause_all", _params, socket) do
    {:ok, _ids} = Custode.pause_all()
    {:noreply, refresh(socket)}
  end

  def handle_event("resume_all", _params, socket) do
    {:ok, _ids} = Custode.resume_all()
    {:noreply, refresh(socket)}
  end

  def handle_event("filter", %{"tag" => tag}, socket) do
    # clicking the active tag clears the filter
    filter = if socket.assigns.tag_filter == tag, do: nil, else: tag
    {:noreply, socket |> assign(tag_filter: filter) |> refresh()}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:fleet}>
      <div class="mb-4 flex flex-wrap items-center gap-2">
        <button
          :for={tag <- @all_tags}
          class={["badge cursor-pointer", (@tag_filter == tag && "badge-primary") || "badge-ghost"]}
          phx-click="filter"
          phx-value-tag={tag}
        >
          {tag}
        </button>
        <span class="ml-auto flex gap-2">
          <button
            :if={@any_pausable}
            class="btn btn-outline btn-error btn-xs"
            phx-click="pause_all"
            data-confirm="Pause every running agent?"
          >
            pause all
          </button>
          <button
            :if={@any_paused}
            class="btn btn-outline btn-success btn-xs"
            phx-click="resume_all"
          >
            resume all
          </button>
        </span>
      </div>
      <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
        <.tile :for={{id, tile} <- @tiles} id={id} tile={tile} />
      </div>
    </.page>
    """
  end

  attr(:id, :string, required: true)
  attr(:tile, :map, required: true)

  defp tile(assigns) do
    ~H"""
    <div
      class={[
        "card bg-base-100 shadow transition hover:shadow-lg",
        tile_ring(@tile.state)
      ]}
      id={"tile-#{@id}"}
    >
      <div class="card-body gap-2 p-4">
        <div class="flex items-center gap-2">
          <.link navigate={"/agents/#{@id}"} class="font-mono font-bold hover:underline">
            {@id}
          </.link>
          <span class={["badge badge-sm", state_badge(@tile.state)]}>{@tile.state}</span>
          <button
            :if={@tile.routine}
            class="btn btn-ghost btn-xs ml-auto"
            phx-click="beat"
            phx-value-id={@id}
          >
            beat
          </button>
        </div>

        <div
          :if={@tile.routine}
          class="-mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/40"
        >
          <span class="font-mono">{@tile.routine.cron}</span>
          <span :for={tag <- @tile.routine.tags} class="badge badge-ghost badge-xs">{tag}</span>
        </div>

        <div class="flex gap-4 text-xs text-base-content/60">
          <span :if={@tile.spend_today}>
            today <b>${usd(@tile.spend_today)}</b><span :if={@tile.budget}> / ${usd(@tile.budget)}</span>
          </span>
          <span :if={@tile.open_todos > 0}>{@tile.open_todos} todo(s)</span>
          <span :if={@tile.state == :offline}>next beat starts it</span>
        </div>

        <div :if={@tile.last} class="rounded-lg bg-base-200/60 p-2 text-sm">
          <div class="mb-1 flex items-center gap-2 text-xs text-base-content/50">
            <span class={["badge badge-xs", feed_badge(@tile.last["event"])]}>
              {@tile.last["event"]}
            </span>
            <span class="font-mono"><.ago at={@tile.last["at"]} /></span>
          </div>
          <p class="line-clamp-3 text-base-content/80">
            {@tile.last["summary"] || @tile.last["action"] || @tile.last["question"] ||
              @tile.last["kind"]}
          </p>
        </div>

        <div
          :if={match?({:awaiting_permission, _}, @tile.status)}
          class="flex items-center gap-2 rounded-lg bg-warning/15 p-2 text-sm"
        >
          <span class="line-clamp-2 flex-1">{elem(@tile.status, 1).description}</span>
          <button
            class="btn btn-success btn-xs"
            phx-click="approve"
            phx-value-id={@id}
            phx-value-action={elem(@tile.status, 1).id}
          >
            approve
          </button>
          <button
            class="btn btn-ghost btn-xs"
            phx-click="reject"
            phx-value-id={@id}
            phx-value-action={elem(@tile.status, 1).id}
          >
            reject
          </button>
        </div>

        <div
          :if={match?({:waiting_for_user, _}, @tile.status)}
          class="rounded-lg bg-accent/15 p-2 text-sm"
        >
          <span class="line-clamp-2">{elem(@tile.status, 1)}</span>
          <.link navigate={"/agents/#{@id}"} class="link link-accent text-xs">
            answer &rarr;
          </.link>
        </div>
      </div>
    </div>
    """
  end

  defp refresh(socket) do
    routines = Routine.all()
    routine_ids = Enum.map(routines, & &1.id)
    running = Agent.list() |> Map.new()
    all_ids = Enum.uniq(routine_ids ++ Map.keys(running))
    routines_by_id = Map.new(routines, &{&1.id, &1})

    tiles =
      for id <- all_ids do
        status = Map.get(running, id, :offline)
        routine = routines_by_id[id]

        {id,
         %{
           status: status,
           state: state_of(status),
           routine: routine,
           budget: routine && routine.daily_budget_usd,
           spend_today: Custode.SpendLedger.today(id),
           open_todos: length(Custode.Notebook.todos(id)),
           last: Custode.Feed.last_message(id, needs_attention?(status))
         }}
      end

    # ghost tiles (#11): recently-ended ephemerals whose trail persists --
    # seen in the feed within the window, not running, not a routine
    ghost_ids =
      Custode.Feed.recent_agents(Application.get_env(:custode, :ghost_window_s, 3_600)) --
        (all_ids ++ routine_ids)

    ghosts =
      for id <- ghost_ids do
        {id,
         %{
           status: :ended,
           state: :ended,
           routine: nil,
           budget: nil,
           spend_today: Custode.SpendLedger.today(id),
           open_todos: 0,
           last: Custode.Feed.last_for(id)
         }}
      end

    # anything needing a human sorts first; then config order, then the
    # living rest; ended ghosts always last
    order = Map.new(Enum.with_index(routine_ids))

    tiles =
      (tiles ++ ghosts)
      |> filter_tiles(socket.assigns[:tag_filter])
      |> Enum.sort_by(fn {id, tile} ->
        {if(needs_attention?(tile.status), do: 0, else: 1),
         if(tile.state == :ended, do: 1, else: 0), Map.get(order, id, 999), id}
      end)

    all_tags =
      routines |> Enum.flat_map(& &1.tags) |> Enum.uniq() |> Enum.map(&to_string/1) |> Enum.sort()

    states = Enum.map(running, fn {_id, status} -> state_of(status) end)

    assign(socket,
      tiles: tiles,
      all_tags: all_tags,
      any_pausable: Enum.any?(states, &(&1 not in [:paused, :offline])),
      any_paused: :paused in states,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  # non-routine agents (sub-agents) have no tags and hide under any filter
  defp filter_tiles(tiles, nil), do: tiles

  defp filter_tiles(tiles, tag) do
    Enum.filter(tiles, fn {_id, tile} ->
      tile.routine != nil and tag in Enum.map(tile.routine.tags, &to_string/1)
    end)
  end

  defp tile_ring(:ended), do: "opacity-60"
  defp tile_ring(:awaiting_permission), do: "ring-2 ring-warning"
  defp tile_ring(:waiting_for_user), do: "ring-2 ring-accent"
  defp tile_ring(:paused), do: "ring-2 ring-error"
  defp tile_ring(_state), do: nil

  defp state_of({state, _payload}), do: state
  defp state_of(state) when is_atom(state), do: state
end
