defmodule CustodeWeb.ConsoleLive do
  @moduledoc """
  The console (#450, design/010 rung 2): one page to see the fleet, act on
  it, and talk to it. Built from the design session's `console.png`.

  Three panes:

    * the RAIL lists every subject, grouped by what it needs. The grouping
      and the order are `Custode.Attention.Fleet.by_group/0` and nothing else:
      this page contains no ranking of its own (design/007).
    * the SUBJECT pane is the selected agent: who it is, what it has been
      doing, and a message box that is always there. There is no state in
      which the operator cannot speak to an agent.
    * the ITEM pane is the subject's signal and what would clear it. Its
      controls are the signal's own `resolving` ops, so a new signal kind
      brings its buttons with it.

  Every `handle_event` here calls `Custode.Operator.Actions` and holds no
  business logic (design/010 decision 4).

  The rail entries are what the operator comes back to, which design/010
  calls topics. Today a topic is a routine, one per repository.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

  alias Custode.Attention
  alias Custode.Operator.Actions
  alias Custode.Signal

  @tabs ~w(attention activity work notebook)
  @opts [via: :liveview]

  @group_titles %{
    needs_you: "needs you",
    watching: "watching",
    working: "working",
    scheduled: "scheduled",
    quiet: "quiet"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    {:ok,
     assign(socket,
       filter: "",
       tab: "attention",
       selected: nil,
       message_gen: 0,
       notice: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(selected: params["id"], notice: nil) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:repo_overview, _repo}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("filter", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(filter: q) |> refresh()}

  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("message", %{"text" => text}, socket) do
    case Actions.message(socket.assigns.selected, text, @opts) do
      {:ok, how} -> after_action(:ok, socket, sent_notice(how))
      {:error, reason} -> after_action({:error, reason}, socket, nil)
    end
  end

  def handle_event("beat", _params, socket),
    do: socket.assigns.selected |> Actions.beat(@opts) |> after_action(socket, "beat queued")

  def handle_event("pause", _params, socket),
    do: socket.assigns.selected |> Actions.pause(@opts) |> after_action(socket, "paused")

  def handle_event("resume", _params, socket),
    do: socket.assigns.selected |> Actions.resume(@opts) |> after_action(socket, "resumed")

  # The shared reject form (#438) posts agent, action, reason and one_off.
  def handle_event("reject", %{"agent" => agent, "action" => action} = params, socket) do
    :reject
    |> Actions.run(%{agent: agent, action: action}, params, @opts)
    |> after_action(socket, "rejected")
  end

  # Any other op comes from the selected subject's own signal. The args are
  # read back from that signal, never from the client, so a stale or forged
  # click cannot name a different agent or action.
  def handle_event("op", %{"op" => op} = params, socket) do
    with %Signal{resolving: resolving} <- socket.assigns.signal,
         %{op: atom, args: args} <- Enum.find(resolving, &(to_string(&1.op) == op)) do
      atom |> Actions.run(args, params, @opts) |> after_action(socket, to_string(atom))
    else
      _stale -> {:noreply, socket |> assign(notice: "that is no longer pending") |> refresh()}
    end
  end

  defp sent_notice(:delivered), do: "sent"
  defp sent_notice(:resumed), do: "resumed, then sent"
  defp sent_notice(:started), do: "started a turn with your message"

  defp after_action(:ok, socket, notice) do
    {:noreply,
     socket
     |> assign(notice: notice, message_gen: socket.assigns.message_gen + 1)
     |> refresh()}
  end

  defp after_action({:error, :empty}, socket, _notice), do: {:noreply, socket}

  defp after_action({:error, reason}, socket, _notice),
    do: {:noreply, socket |> assign(notice: "failed: #{inspect(reason)}") |> refresh()}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex min-h-screen flex-col">
      <header class="flex items-baseline gap-4 border-b border-base-300 bg-base-100 px-5 py-3">
        <.link navigate="/console" class="text-xl font-bold hover:opacity-70">custode</.link>
        <nav class="flex gap-3 text-sm text-base-content/60">
          <span class="font-semibold text-base-content underline underline-offset-4">console</span>
          <.link navigate="/" class="hover:text-base-content">fleet</.link>
          <.link navigate="/inbox" class="hover:text-base-content">inbox</.link>
          <.link navigate="/repos" class="hover:text-base-content">repos</.link>
          <.link navigate="/workflows" class="hover:text-base-content">workflows</.link>
          <.link navigate="/metrics" class="hover:text-base-content">metrics</.link>
        </nav>
        <span :if={@needs_you > 0} class="badge badge-warning ml-auto whitespace-nowrap">
          {@needs_you} need you
        </span>
        <span class={["font-mono text-sm text-base-content/60", @needs_you == 0 && "ml-auto"]}>
          fleet today ${usd(@fleet_today)}
        </span>
      </header>

      <div class="px-5 pt-4 empty:hidden"><.host_banner /></div>

      <div class="grid flex-1 grid-cols-1 md:grid-cols-[17rem_1fr] xl:grid-cols-[17rem_1fr_24rem]">
        <.rail groups={@groups} selected={@selected} filter={@filter} in_flight={@in_flight} />

        <main class="min-w-0 border-base-300 p-6 md:border-l">
          <p :if={@subject == nil} class="text-base-content/50">
            Pick a subject from the rail.
          </p>
          <.subject
            :if={@subject}
            subject={@subject}
            signal={@signal}
            tab={@tab}
            notice={@notice}
            message_gen={@message_gen}
          />
        </main>

        <%!-- under the subject at medium widths, its own column when there is room --%>
        <aside class="border-base-300 bg-base-100 p-6 md:col-start-2 md:border-l md:border-t xl:col-start-auto xl:border-t-0">
          <.item :if={@subject} signal={@signal} message_gen={@message_gen} />
        </aside>
      </div>
    </div>
    """
  end

  # -- the rail ---------------------------------------------------------------

  attr(:groups, :list, required: true)
  attr(:selected, :string, default: nil)
  attr(:filter, :string, required: true)
  attr(:in_flight, :map, required: true)

  defp rail(assigns) do
    ~H"""
    <nav class="bg-base-100 p-4" aria-label="subjects">
      <form id="rail-filter" phx-change="filter" phx-submit="filter" class="mb-4">
        <input
          type="search"
          name="q"
          value={@filter}
          placeholder="filter"
          autocomplete="off"
          phx-debounce="150"
          class="input input-bordered input-sm w-full"
        />
      </form>

      <p :if={@groups == []} class="text-sm text-base-content/50">nothing matches</p>

      <section :for={{group, signals} <- @groups} class="mb-5">
        <h2 class={["mb-1 text-xs font-bold uppercase tracking-widest", group_tone(group)]}>
          {group_title(group)}
          <span class="font-normal text-base-content/40">{length(signals)}</span>
        </h2>
        <ul>
          <li :for={signal <- signals}>
            <.link
              patch={"/console/#{signal.subject}"}
              class={[
                "flex items-center gap-2 rounded px-2 py-1.5 font-mono text-sm hover:bg-base-200",
                signal.subject == @selected && "bg-base-200 font-bold",
                group in [:scheduled, :quiet] && "text-base-content/60"
              ]}
            >
              <span class={["inline-block size-2 shrink-0 rounded-full", dot(signal)]}></span>
              <span class="truncate">{signal.subject}</span>
              <span class="ml-auto shrink-0 text-xs font-normal text-base-content/50">
                {rail_note(signal, @in_flight)}
              </span>
            </.link>
          </li>
        </ul>
      </section>
    </nav>
    """
  end

  # -- the subject pane -------------------------------------------------------

  attr(:subject, :map, required: true)
  attr(:signal, :any, required: true)
  attr(:tab, :string, required: true)
  attr(:notice, :string, default: nil)
  attr(:message_gen, :integer, required: true)

  defp subject(assigns) do
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <h1 class="font-mono text-2xl font-bold">{@subject.id}</h1>
      <.status_badge status={@subject.status} />
      <div class="ml-auto flex gap-2">
        <button class="btn btn-outline btn-sm" phx-click="beat">beat now</button>
        <button :if={@subject.state != :paused} class="btn btn-outline btn-sm" phx-click="pause">
          pause
        </button>
        <button :if={@subject.state == :paused} class="btn btn-outline btn-sm" phx-click="resume">
          resume
        </button>
      </div>
    </div>

    <p class="mt-1 font-mono text-xs text-base-content/60">{facts(@subject)}</p>

    <%!-- Always here, whatever the agent's state (#450). The button says
          what sending will do: queue, answer, resume first, or start a turn. --%>
    <form id={"message-#{@message_gen}"} phx-submit="message" class="mt-4 flex gap-2">
      <textarea
        name="text"
        rows="2"
        class="textarea textarea-bordered w-full text-sm"
        placeholder={"message #{@subject.id}... #{message_hint(@subject.state)}"}
      ></textarea>
      <button type="submit" class="btn btn-primary btn-sm self-end">
        {message_label(@subject.state)}
      </button>
    </form>
    <p :if={@notice} class="mt-1 text-xs text-base-content/60">{@notice}</p>

    <div role="tablist" class="tabs tabs-border mt-6">
      <button
        :for={tab <- tabs()}
        role="tab"
        phx-click="tab"
        phx-value-tab={tab}
        class={["tab", tab == @tab && "tab-active"]}
      >
        {tab}<span :if={tab_count(tab, @subject, @signal)} class="ml-1 font-mono text-xs text-warning">
          {tab_count(tab, @subject, @signal)}
        </span>
      </button>
    </div>

    <div class="mt-4">
      <.attention_tab :if={@tab == "attention"} subject={@subject} signal={@signal} />
      <.activity_tab :if={@tab == "activity"} subject={@subject} />
      <.work_tab :if={@tab == "work"} subject={@subject} />
      <.notebook_tab :if={@tab == "notebook"} subject={@subject} />
    </div>
    """
  end

  attr(:subject, :map, required: true)
  attr(:signal, :any, required: true)

  defp attention_tab(assigns) do
    ~H"""
    <%!-- the item pane says this when it has its own column, so it is only
          drawn here when it does not --%>
    <div class={["rounded-xl border p-4 xl:hidden", signal_frame(@signal)]}>
      <p class="font-semibold">{@signal.headline}</p>
      <p :if={@signal.detail} class="mt-1 whitespace-pre-line text-sm text-base-content/70">
        {@signal.detail}
      </p>
      <p :if={@signal.raised_at} class="mt-2 font-mono text-xs text-base-content/40">
        raised <.ago at={@signal.raised_at} />
      </p>
    </div>

    <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50 xl:mt-0">
      last said
    </h3>
    <p :if={@subject.feed == []} class="text-sm text-base-content/50">nothing yet</p>
    <div class="flex flex-col gap-2">
      <.feed_entry :for={entry <- Enum.take(@subject.feed, 3)} entry={entry} show_agent={false} />
    </div>
    """
  end

  attr(:subject, :map, required: true)

  defp activity_tab(assigns) do
    ~H"""
    <p :if={@subject.feed == []} class="text-sm text-base-content/50">no activity yet</p>
    <div class="flex flex-col gap-2">
      <.feed_entry :for={entry <- @subject.feed} entry={entry} show_agent={false} />
    </div>
    """
  end

  attr(:subject, :map, required: true)

  defp work_tab(assigns) do
    ~H"""
    <p :if={@subject.repo == nil} class="text-sm text-base-content/50">
      this subject is not tied to a repository
    </p>
    <div :if={@subject.repo}>
      <a
        href={"https://github.com/#{@subject.repo}"}
        target="_blank"
        rel="noopener"
        class="link font-mono text-sm"
      >
        {@subject.repo}
      </a>
      <div class="mt-3"><.repo_overview_panel overview={@subject.overview} /></div>
    </div>
    """
  end

  attr(:subject, :map, required: true)

  defp notebook_tab(assigns) do
    ~H"""
    <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
      todo <span class="font-normal">{length(@subject.todos)}</span>
    </h3>
    <p :if={@subject.todos == []} class="text-sm text-base-content/50">nothing queued</p>
    <ul class="list-inside list-disc text-sm">
      <li :for={todo <- @subject.todos}>{todo.text}</li>
    </ul>

    <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50">
      journal
    </h3>
    <p :if={@subject.journal == []} class="text-sm text-base-content/50">no entries</p>
    <details :for={entry <- @subject.journal} class="border-b border-base-300/60 py-2">
      <summary class="cursor-pointer text-sm">
        <span class="font-medium">{entry.title || "(untitled)"}</span>
        <span class="ml-2 font-mono text-xs text-base-content/40">
          <.ago at={entry.inserted_at} />
        </span>
      </summary>
      <div class="mt-2"><.markdown text={entry.body || ""} /></div>
    </details>
    """
  end

  # -- the item pane ----------------------------------------------------------

  attr(:signal, :any, required: true)
  attr(:message_gen, :integer, required: true)

  defp item(assigns) do
    assigns =
      assign(assigns, :ops, Enum.filter(assigns.signal.resolving, &Actions.handles?(&1.op)))

    ~H"""
    <h2 class="text-xs font-bold uppercase tracking-widest text-base-content/50">
      {if Signal.needs_you?(@signal), do: "needs you", else: "state"}
    </h2>
    <p class="mt-2 font-semibold">{@signal.headline}</p>
    <p :if={@signal.detail} class="mt-2 whitespace-pre-line text-sm text-base-content/70">
      {@signal.detail}
    </p>

    <h3
      :if={@ops != []}
      class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50"
    >
      what you can do
    </h3>
    <div class="flex flex-wrap items-start gap-2">
      <.op :for={op <- @ops} op={op} message_gen={@message_gen} />
    </div>
    """
  end

  attr(:op, :map, required: true)
  attr(:message_gen, :integer, required: true)

  # A question is a conversation, so its control is a reply box (#301).
  defp op(%{op: %{op: kind}} = assigns) when kind in [:answer, :answer_ask] do
    ~H"""
    <form
      id={"reply-#{@op.op}-#{@message_gen}"}
      phx-submit="op"
      class="flex w-full flex-col gap-2"
    >
      <input type="hidden" name="op" value={@op.op} />
      <textarea
        name="text"
        rows="4"
        required
        class="textarea textarea-bordered w-full text-sm"
        placeholder="your answer..."
      ></textarea>
      <button type="submit" class="btn btn-primary btn-sm self-end">answer</button>
    </form>
    """
  end

  defp op(%{op: %{op: :reject}} = assigns) do
    ~H"""
    <.reject_form agent={@op.args.agent} action={@op.args.action} size="btn-sm" />
    """
  end

  defp op(assigns) do
    ~H"""
    <button
      class={["btn btn-sm", (@op.op == :approve && "btn-success") || "btn-outline"]}
      phx-click="op"
      phx-value-op={@op.op}
    >
      {String.downcase(@op.label)}
    </button>
    """
  end

  # -- data -------------------------------------------------------------------

  defp refresh(socket) do
    filter = socket.assigns.filter |> String.trim() |> String.downcase()

    # The host signal (#443) has no agent of its own and is drawn as the
    # banner, so it stays out of a rail of subjects.
    signals = Enum.reject(Attention.Fleet.signals(), &(&1.kind == :host_down))

    groups =
      signals
      |> Enum.filter(&(filter == "" or String.contains?(String.downcase(&1.subject), filter)))
      |> Attention.by_group()

    selected = socket.assigns.selected || default_selection(signals)
    signal = Enum.find(signals, &(&1.subject == selected))

    assign(socket,
      groups: groups,
      selected: selected,
      signal: signal,
      subject: signal && load_subject(selected),
      in_flight: Custode.RunClock.running(),
      needs_you: Enum.count(signals, &Signal.needs_you?/1),
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  # What most needs the operator is the right thing to open on.
  defp default_selection([first | _rest]), do: first.subject
  defp default_selection([]), do: nil

  defp load_subject(id) do
    routine = Custode.Routine.get(id)
    {:ok, status} = ObanClaude.Agent.status(id)
    repo = routine && routine.repo

    %{
      id: id,
      routine: routine,
      status: status,
      state: Custode.state_of(status),
      repo: repo,
      overview: repo && overview(repo),
      spend_today: Custode.SpendLedger.today(id),
      feed: Custode.Feed.for_agent(id, 30),
      todos: Custode.Notebook.todos(id),
      journal: Custode.Notebook.journal(id, 10)
    }
  end

  defp overview(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} -> overview
      :loading -> :loading
    end
  end

  # -- words and tones ----------------------------------------------------------

  defp tabs, do: @tabs

  defp group_title(group), do: Map.fetch!(@group_titles, group)

  defp group_tone(:needs_you), do: "text-warning"
  defp group_tone(:watching), do: "text-warning/70"
  defp group_tone(:working), do: "text-info"
  defp group_tone(_group), do: "text-base-content/50"

  # One meaning per color (guides/ui-hierarchy.md): red is blocked on you,
  # yellow wants you, blue is working, grey is ambient.
  defp dot(%Signal{kind: kind}) when kind in [:red_main, :rail_hit, :disowned_check],
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

  defp rail_note(%Signal{kind: :approval}, _in_flight), do: "gate"
  defp rail_note(%Signal{kind: :needs_answer}, _in_flight), do: "asked"
  defp rail_note(%Signal{kind: :rail_hit}, _in_flight), do: "rail"
  defp rail_note(%Signal{kind: :paused}, _in_flight), do: "paused"
  defp rail_note(%Signal{}, _in_flight), do: ""

  defp elapsed(seconds) when seconds >= 60, do: "#{div(seconds, 60)}m"
  defp elapsed(seconds), do: "#{max(seconds, 0)}s"

  defp facts(%{routine: nil}), do: "no routine: a sub-agent or a one-shot"

  defp facts(%{routine: routine, spend_today: spend}) do
    [
      routine.role,
      routine.model,
      routine.cron,
      routine.repo,
      "$#{usd(spend)}" <> budget(routine.daily_budget_usd)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(" · ", &to_string/1)
  end

  defp budget(nil), do: " today"
  defp budget(limit), do: " of $#{usd(limit)}"

  # The label says what sending will DO, because for two states it does more
  # than send (see `Custode.Operator.Actions.message/3`).
  defp message_label(:running), do: "queue"
  defp message_label(:waiting_for_user), do: "answer"
  defp message_label(:paused), do: "resume + send"
  defp message_label(:offline), do: "start + send"
  defp message_label(_state), do: "send"

  defp message_hint(:running), do: "(it is mid-turn: this queues)"
  defp message_hint(:paused), do: "(paused: sending resumes it)"
  defp message_hint(:offline), do: "(offline: this starts a turn with your message)"
  defp message_hint(:waiting_for_user), do: "(it is waiting on you: this is the answer)"
  defp message_hint(_state), do: ""

  defp tab_count("attention", _subject, %Signal{} = signal),
    do: if(Signal.needs_you?(signal), do: 1)

  defp tab_count("notebook", %{todos: [_one | _rest] = todos}, _signal), do: length(todos)
  defp tab_count(_tab, _subject, _signal), do: nil

  defp signal_frame(%Signal{kind: kind}) when kind in [:red_main, :rail_hit, :disowned_check],
    do: "border-error/40 bg-error/5"

  defp signal_frame(%Signal{group: :needs_you}), do: "border-warning/50 bg-warning/5"
  defp signal_frame(%Signal{}), do: "border-base-300/60"
end
