defmodule CustodeWeb.FleetLive do
  @moduledoc """
  The fleet page: one card per configured routine (plus any other running
  agents, e.g. sub-agents), each with its live status, spend, pending gates
  (approve / reject / answer inline), a prompt box, and pause/resume -- and
  the activity feed streaming down the side.

  All reads go through the facade (`status`/`info` are cheap); all pushes
  arrive over `Custode.PubSubBridge` -- no polling anywhere.
  """

  use Phoenix.LiveView

  alias Custode.Routine
  alias ObanClaude.Agent

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    feed = Custode.Feed.tail(30) |> Enum.reverse()

    socket =
      socket
      |> assign(routines: Routine.all())
      |> refresh_agents()
      |> stream_configure(:feed, dom_id: &feed_dom_id/1)
      |> stream(:feed, feed)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info({:feed_entry, entry}, socket) do
    {:noreply, socket |> stream_insert(:feed, entry, at: 0) |> refresh_agents()}
  end

  def handle_info({:notebook_changed, _routine_id}, socket) do
    {:noreply, refresh_agents(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("beat", %{"id" => id}, socket) do
    {:ok, _job} = Custode.beat(id)
    {:noreply, socket}
  end

  def handle_event("prompt", %{"agent" => id, "text" => text}, socket) do
    if String.trim(text) != "", do: Agent.cast_prompt(id, text)
    {:noreply, refresh_agents(socket)}
  end

  def handle_event("approve", %{"id" => id, "action" => action_id}, socket) do
    Agent.approve_action(id, action_id)
    {:noreply, refresh_agents(socket)}
  end

  def handle_event("reject", %{"id" => id, "action" => action_id}, socket) do
    Agent.reject_action(id, action_id, "rejected from dashboard")
    {:noreply, refresh_agents(socket)}
  end

  def handle_event("pause", %{"id" => id}, socket) do
    Agent.emergency_pause(id)
    {:noreply, refresh_agents(socket)}
  end

  def handle_event("resume", %{"id" => id}, socket) do
    Agent.resume_agent(id)
    {:noreply, refresh_agents(socket)}
  end

  def handle_event("todo_done", %{"todo" => todo_id}, socket) do
    Custode.Notebook.todo_complete(String.to_integer(todo_id))
    {:noreply, refresh_agents(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-7xl p-6">
      <header class="mb-6 flex items-baseline gap-3">
        <h1 class="text-3xl font-bold">custode</h1>
        <span class="text-base-content/60">the caretaker fleet</span>
        <span class="ml-auto font-mono text-sm text-base-content/70">
          fleet today ${Float.round(@fleet_today, 4)}
        </span>
      </header>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-3">
        <div class="space-y-4 lg:col-span-2">
          <.agent_card
            :for={routine <- @routines}
            id={routine.id}
            agent={@agents[routine.id]}
            routine={routine}
            notebook={@notebooks[routine.id]}
            spend_today={@spend[routine.id]}
          />

          <div :if={@others != []}>
            <h2 class="mb-2 mt-6 text-lg font-semibold text-base-content/70">other agents</h2>
            <div class="space-y-4">
              <.agent_card
                :for={id <- @others}
                id={id}
                agent={@agents[id]}
                routine={nil}
                notebook={nil}
                spend_today={nil}
              />
            </div>
          </div>
        </div>

        <div>
          <h2 class="mb-2 text-lg font-semibold text-base-content/70">feed</h2>
          <ul id="feed" phx-update="stream" class="space-y-2">
            <li :for={{dom_id, entry} <- @streams.feed} id={dom_id} class="card bg-base-100 shadow-sm">
              <div class="card-body p-3 text-sm">
                <div class="flex items-center gap-2">
                  <span class={["badge badge-sm", feed_badge(entry["event"])]}>{entry["event"]}</span>
                  <span class="font-mono text-xs text-base-content/60">
                    {String.slice(entry["at"] || "", 11, 8)} {entry["agent"]}
                  </span>
                  <span :if={entry["cost_usd"]} class="ml-auto font-mono text-xs">
                    ${entry["cost_usd"]}
                  </span>
                </div>
                <p class="text-base-content/80">
                  {entry["summary"] || entry["action"] || entry["question"] || entry["kind"]}
                </p>
              </div>
            </li>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp agent_card(assigns) do
    ~H"""
    <div class="card bg-base-100 shadow" id={"agent-#{@id}"}>
      <div class="card-body">
        <div class="flex items-center gap-3">
          <h2 class="card-title font-mono">{@id}</h2>
          <span class={["badge", state_badge(@agent.state)]}>{@agent.state}</span>
          <span :if={@routine} class="font-mono text-xs text-base-content/50">{@routine.cron}</span>
          <div class="ml-auto flex gap-2">
            <button :if={@routine} class="btn btn-xs" phx-click="beat" phx-value-id={@id}>
              beat
            </button>
            <button
              :if={@agent.state not in [:offline, :paused]}
              class="btn btn-xs btn-outline btn-error"
              phx-click="pause"
              phx-value-id={@id}
            >
              pause
            </button>
            <button
              :if={@agent.state == :paused}
              class="btn btn-xs btn-outline btn-success"
              phx-click="resume"
              phx-value-id={@id}
            >
              resume
            </button>
          </div>
        </div>

        <div class="flex gap-6 text-sm text-base-content/70">
          <span :if={@agent.info}>turns <b>{@agent.info.turns}</b></span>
          <span :if={@spend_today}>
            today <b>${Float.round(@spend_today, 4)}</b>
            <span :if={@routine && @routine.daily_budget_usd} class="text-base-content/50">
              / ${@routine.daily_budget_usd}
            </span>
          </span>
          <span
            :if={@agent.info && @agent.info.session_id}
            class="truncate font-mono text-xs"
          >
            {String.slice(@agent.info.session_id, 0, 8)}
          </span>
        </div>

        <p :if={@agent.state == :offline} class="text-sm text-base-content/50">
          offline -- the next beat starts it
        </p>

        <div :if={@notebook} class="text-sm">
          <div :if={@notebook.todos != []}>
            <p class="font-semibold text-base-content/70">todo</p>
            <ul class="mt-1 space-y-1">
              <li :for={todo <- @notebook.todos} class="flex items-center gap-2">
                <button
                  class="btn btn-ghost btn-xs"
                  title="mark done"
                  phx-click="todo_done"
                  phx-value-todo={todo.id}
                >
                  ✓
                </button>
                <span>{todo.text}</span>
              </li>
            </ul>
          </div>
          <p :if={@notebook.latest} class="mt-1 text-xs text-base-content/60">
            journal: {@notebook.journal_count} entries, latest: {@notebook.latest}
          </p>
        </div>

        <div :if={match?({:awaiting_permission, _}, @agent.status)} class="alert alert-warning">
          <div class="flex-1">
            <p class="font-semibold">wants permission:</p>
            <p class="text-sm">{elem(@agent.status, 1).description}</p>
          </div>
          <div class="flex gap-2">
            <button
              class="btn btn-sm btn-success"
              phx-click="approve"
              phx-value-id={@id}
              phx-value-action={elem(@agent.status, 1).id}
            >
              approve
            </button>
            <button
              class="btn btn-sm btn-ghost"
              phx-click="reject"
              phx-value-id={@id}
              phx-value-action={elem(@agent.status, 1).id}
            >
              reject
            </button>
          </div>
        </div>

        <div :if={match?({:waiting_for_user, _}, @agent.status)} class="alert alert-info">
          <div class="w-full">
            <p class="font-semibold">asks: {elem(@agent.status, 1)}</p>
            <form phx-submit="prompt" class="mt-2 flex gap-2">
              <input type="hidden" name="agent" value={@id} />
              <input
                type="text"
                name="text"
                placeholder="your answer..."
                class="input input-sm input-bordered flex-1"
                autocomplete="off"
              />
              <button class="btn btn-sm btn-primary">answer</button>
            </form>
          </div>
        </div>

        <form
          :if={@agent.state not in [:offline, :paused]}
          phx-submit="prompt"
          class="mt-2 flex gap-2"
        >
          <input type="hidden" name="agent" value={@id} />
          <input
            type="text"
            name="text"
            placeholder={"prompt #{@id}..."}
            class="input input-sm input-bordered flex-1 font-mono"
            autocomplete="off"
          />
          <button class="btn btn-sm btn-primary">send</button>
        </form>
      </div>
    </div>
    """
  end

  # one snapshot per agent: the atomic status plus the info ledger (nil offline)
  defp refresh_agents(socket) do
    routines = Routine.all()
    routine_ids = Enum.map(routines, & &1.id)
    running = Agent.list() |> Map.new()
    all_ids = Enum.uniq(routine_ids ++ Map.keys(running))

    agents =
      Map.new(all_ids, fn id ->
        status = Map.get(running, id, :offline)

        info =
          case Agent.info(id) do
            {:ok, info} -> info
            {:error, _reason} -> nil
          end

        {id, %{status: status, state: state_of(status), info: info}}
      end)

    others = (all_ids -- routine_ids) |> Enum.sort()

    notebooks =
      Map.new(routine_ids, fn id ->
        latest =
          case Custode.Notebook.journal(id, 1) do
            [entry] -> entry.title || String.slice(entry.body, 0, 60)
            [] -> nil
          end

        journal_count = length(Custode.Notebook.journal(id, 200))
        {id, %{todos: Custode.Notebook.todos(id), latest: latest, journal_count: journal_count}}
      end)

    spend = Map.new(routine_ids, fn id -> {id, Custode.SpendLedger.today(id)} end)

    assign(socket,
      routines: routines,
      agents: agents,
      others: others,
      notebooks: notebooks,
      spend: spend,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  defp state_of({state, _payload}), do: state
  defp state_of(state) when is_atom(state), do: state

  defp state_badge(:idle), do: "badge-ghost"
  defp state_badge(:running), do: "badge-info"
  defp state_badge(:awaiting_permission), do: "badge-warning"
  defp state_badge(:waiting_for_user), do: "badge-accent"
  defp state_badge(:paused), do: "badge-error"
  defp state_badge(_state), do: "badge-outline"

  defp feed_badge("turn"), do: "badge-info"
  defp feed_badge("turn_failed"), do: "badge-error"
  defp feed_badge("needs_approval"), do: "badge-warning"
  defp feed_badge("needs_input"), do: "badge-accent"
  defp feed_badge(_event), do: "badge-ghost"

  defp feed_dom_id(entry) do
    "feed-" <> Integer.to_string(:erlang.phash2({entry["at"], entry["event"], entry["agent"]}))
  end
end
