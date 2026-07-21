defmodule CustodeWeb.AgentLive do
  @moduledoc """
  Everything for one agent: full status and controls (prompt, answer,
  approve/reject, pause/resume, beat), the notebook (todos, journal),
  memories, its slice of the feed, and the machine's own event log.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  alias ObanClaude.Agent

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    {:ok, socket |> assign(id: id) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("prompt", %{"text" => text}, socket) do
    if String.trim(text) != "", do: Agent.cast_prompt(socket.assigns.id, text)
    {:noreply, refresh(socket)}
  end

  def handle_event("approve", %{"action" => action_id}, socket) do
    Agent.approve_action(socket.assigns.id, action_id)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"action" => action_id}, socket) do
    Agent.reject_action(socket.assigns.id, action_id, "rejected from dashboard")
    {:noreply, refresh(socket)}
  end

  def handle_event("pause", _params, socket) do
    Agent.emergency_pause(socket.assigns.id)
    {:noreply, refresh(socket)}
  end

  def handle_event("resume", _params, socket) do
    Agent.resume_agent(socket.assigns.id)
    {:noreply, refresh(socket)}
  end

  def handle_event("beat", _params, socket) do
    {:ok, _job} = Custode.beat(socket.assigns.id)
    {:noreply, socket}
  end

  def handle_event("todo_done", %{"todo" => todo_id}, socket) do
    Custode.Notebook.todo_complete(String.to_integer(todo_id))
    {:noreply, refresh(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:fleet}>
      <div class="mb-4 flex items-center gap-3">
        <h2 class="font-mono text-2xl font-bold">{@id}</h2>
        <span class={["badge", state_badge(@state)]}>{@state}</span>
        <span :if={@routine} class="font-mono text-xs text-base-content/50">{@routine.cron}</span>
        <div class="ml-auto flex gap-2">
          <button :if={@routine} class="btn btn-xs" phx-click="beat">beat</button>
          <button
            :if={@state not in [:offline, :paused]}
            class="btn btn-outline btn-error btn-xs"
            phx-click="pause"
          >
            pause
          </button>
          <button :if={@state == :paused} class="btn btn-outline btn-success btn-xs" phx-click="resume">
            resume
          </button>
        </div>
      </div>

      <div class="mb-4 flex flex-wrap gap-6 text-sm text-base-content/70">
        <span>today <b>${Float.round(@spend_today, 4)}</b><span :if={@routine && @routine.daily_budget_usd}> / ${@routine.daily_budget_usd}</span></span>
        <span :if={@info}>turns <b>{@info.turns}</b></span>
        <span :if={@info && @info.session_id} class="font-mono text-xs">
          session {String.slice(@info.session_id, 0, 8)}
        </span>
        <span :if={@routine} class="text-xs">workspace {@routine.workspace}</span>
      </div>

      <p :if={@state == :offline} class="mb-4 text-sm text-base-content/50">
        offline -- the next beat starts it
      </p>

      <div :if={match?({:awaiting_permission, _}, @status)} class="alert alert-warning mb-4">
        <div class="flex-1">
          <p class="font-semibold">wants permission:</p>
          <p class="text-sm">{elem(@status, 1).description}</p>
        </div>
        <div class="flex gap-2">
          <button class="btn btn-success btn-sm" phx-click="approve" phx-value-action={elem(@status, 1).id}>
            approve
          </button>
          <button class="btn btn-ghost btn-sm" phx-click="reject" phx-value-action={elem(@status, 1).id}>
            reject
          </button>
        </div>
      </div>

      <div :if={match?({:waiting_for_user, _}, @status)} class="alert alert-info mb-4">
        <div class="w-full">
          <p class="font-semibold">asks: {elem(@status, 1)}</p>
          <form phx-submit="prompt" class="mt-2 flex gap-2">
            <input
              type="text"
              name="text"
              placeholder="your answer..."
              class="input input-sm input-bordered flex-1"
              autocomplete="off"
            />
            <button class="btn btn-primary btn-sm">answer</button>
          </form>
        </div>
      </div>

      <form :if={@state not in [:offline, :paused]} phx-submit="prompt" class="mb-6 flex gap-2">
        <input
          type="text"
          name="text"
          placeholder={"prompt #{@id}..."}
          class="input input-sm input-bordered flex-1 font-mono"
          autocomplete="off"
        />
        <button class="btn btn-primary btn-sm">send</button>
      </form>

      <div class="grid grid-cols-1 gap-6 lg:grid-cols-2">
        <div class="space-y-6">
          <section :if={@routine}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">todo</h3>
            <p :if={@todos == []} class="text-sm text-base-content/40">(nothing open)</p>
            <ul class="space-y-1 text-sm">
              <li :for={todo <- @todos} class="flex items-center gap-2">
                <button
                  class="btn btn-ghost btn-xs"
                  title="mark done"
                  phx-click="todo_done"
                  phx-value-todo={todo.id}
                >
                  &#10003;
                </button>
                <span>{todo.text}</span>
              </li>
            </ul>
          </section>

          <section :if={@routine}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">journal</h3>
            <p :if={@journal == []} class="text-sm text-base-content/40">(no entries)</p>
            <div :for={entry <- @journal} class="mb-2 rounded-lg bg-base-100 p-3 text-sm shadow-sm">
              <p class="mb-1 text-xs text-base-content/50">
                {Calendar.strftime(entry.inserted_at, "%m-%d %H:%M")}
                <b :if={entry.title}>{entry.title}</b>
                <span class="text-base-content/40">({entry.source})</span>
              </p>
              <p class="whitespace-pre-wrap text-base-content/80">{entry.body}</p>
            </div>
          </section>

          <section :if={@memories != []}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">memory</h3>
            <div :for={memory <- @memories} class="mb-1 text-sm">
              <span class="font-mono text-xs text-base-content/50">{memory.key}:</span>
              {memory.value}
            </div>
          </section>

          <section :if={@history != []}>
            <h3 class="mb-2 text-lg font-semibold text-base-content/70">machine log</h3>
            <div class="max-h-64 overflow-y-auto rounded-lg bg-base-100 p-3 font-mono text-xs shadow-sm">
              <p :for={entry <- @history} class="truncate text-base-content/70">
                {inspect(entry, printable_limit: 160)}
              </p>
            </div>
          </section>
        </div>

        <div>
          <h3 class="mb-2 text-lg font-semibold text-base-content/70">activity</h3>
          <p :if={@feed == []} class="text-sm text-base-content/40">(nothing yet)</p>
          <div class="space-y-2">
            <.feed_entry :for={entry <- Enum.reverse(@feed)} entry={entry} show_agent={false} />
          </div>
        </div>
      </div>
    </.page>
    """
  end

  defp refresh(socket) do
    id = socket.assigns.id
    routine = Custode.Routine.get(id)
    {:ok, status} = Agent.status(id)

    info =
      case Agent.info(id) do
        {:ok, info} -> info
        {:error, _reason} -> nil
      end

    history =
      case Agent.history(id) do
        {:ok, history} -> Enum.take(history, -20) |> Enum.reverse()
        {:error, _reason} -> []
      end

    assign(socket,
      routine: routine,
      status: status,
      state: state_of(status),
      info: info,
      history: history,
      spend_today: Custode.SpendLedger.today(id),
      todos: Custode.Notebook.todos(id),
      journal: Custode.Notebook.journal(id, 10),
      memories: Custode.Memory.recall(id),
      feed: Custode.Feed.for_agent(id, 30),
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  defp state_of({state, _payload}), do: state
  defp state_of(state) when is_atom(state), do: state
end
