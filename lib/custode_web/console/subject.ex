defmodule CustodeWeb.Console.Subject do
  @moduledoc """
  The console's subject pane (#450): the selected agent. Who it is, a message
  box that is there in every state, and what it has been doing, in tabs.

  Unsent message drafts live in browser `localStorage`, one key per subject.
  They survive navigation, reload and reconnect until an accepted send or the
  operator's explicit discard. They never enter Custode's feed or database.
  """

  use Phoenix.Component

  import CustodeWeb.Components
  import CustodeWeb.Console.Composer, only: [message_composer: 1]

  alias Custode.ExecutionFacts
  alias Custode.Operator.RoutineEdit
  alias Custode.Signal
  alias CustodeWeb.WorkflowLaunch

  @tabs ~w(attention activity work notebook panel turns config)

  @doc "The tabs, in order. The LiveView guards its `tab` event with them."
  def tabs, do: @tabs

  attr(:subject, :map, required: true)
  attr(:signal, :any, required: true)
  attr(:tab, :string, required: true)
  attr(:notice, :string, default: nil)
  attr(:message_gen, :integer, required: true)
  attr(:edit, :any, default: nil)
  attr(:upload, :map, required: true)
  attr(:running_since, :any, default: nil)

  def subject(assigns) do
    assigns =
      assign(
        assigns,
        :execution,
        ExecutionFacts.read(assigns.subject.id, routine: assigns.subject.routine)
      )

    current_run =
      case Custode.CurrentRun.read(%{kind: :operator, id: "local-ui"}, assigns.subject.id) do
        {:ok, facts} -> facts
        {:error, _reason} -> nil
      end

    assigns = assign(assigns, :current_run, current_run)

    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <h1 class="min-w-0 break-words font-mono text-2xl font-bold">{@subject.id}</h1>
      <.status_badge status={@subject.status} />
      <%!-- A subject is not always an agent: a workflow signal has nothing to
            beat, pause or talk to. Only a routine has a beat. --%>
      <div :if={@subject.kind != :other} class="ml-auto flex flex-wrap gap-2">
        <.link
          navigate={"/agents/#{@subject.id}/conversation"}
          class="btn btn-ghost btn-sm"
        >
          Conversation
        </.link>
        <.link
          :if={@subject.kind == :routine}
          navigate={"/messages?" <> URI.encode_query(%{"agent" => @subject.id})}
          class="btn btn-ghost btn-sm"
        >
          Agent messages
        </.link>
        <button :if={@subject.kind == :routine} class="btn btn-outline btn-sm" phx-click="beat">
          Beat now
        </button>
        <button :if={@subject.state != :paused} class="btn btn-outline btn-sm" phx-click="pause">
          Pause
        </button>
        <button :if={@subject.state == :paused} class="btn btn-outline btn-sm" phx-click="resume">
          Resume
        </button>
      </div>
    </div>

    <p id="subject-execution-facts" class="mt-1 font-mono text-xs text-base-content/60">
      {facts(@subject, @execution)}
    </p>
    <p
      :if={configuration_transition?(@execution)}
      id="subject-config-transition"
      class="mt-1 break-words font-mono text-xs text-warning [overflow-wrap:anywhere]"
    >
      {current_execution_label(@execution)}: {execution_label(current_execution(@execution))} · next turn: {execution_label(
        @execution.desired
      )}
    </p>
    <CustodeWeb.CurrentRunView.strip facts={@current_run} />
    <p :if={@subject.conversation.current} class="mt-1 font-mono text-xs text-base-content/50">
      {conversation_facts(@subject.conversation.current)}
    </p>
    <p :if={@subject.state == :ended} class="mt-2 text-sm text-base-content/50">
      ended -- this was an ephemeral agent; its memory and activity remain available here
    </p>

    <div
      :if={@subject.pending_wake}
      id="pending-inbox-wake"
      class="mt-3 flex flex-wrap items-center gap-2 rounded-box bg-base-200 px-3 py-2 text-xs text-base-content/70"
    >
      <span class="badge badge-outline badge-sm">{wake_reason(@subject.pending_wake.reason)}</span>
      <span>{note_count(@subject.pending_wake)} pending</span>
      <span>{wake_status(@subject.pending_wake)}</span>
      <span :if={@subject.pending_wake.spend_override} class="text-base-content/50">
        manual spend override granted
      </span>
      <span class="ml-auto font-mono text-base-content/50">
        last note <.ago at={@subject.pending_wake.last_note_at} />
      </span>
    </div>

    <div
      :if={@running_since}
      id="working-state"
      class="mt-3 flex items-center gap-2 rounded-lg bg-info/5 px-3 py-2 text-xs text-base-content/70"
    >
      <span class="badge badge-info badge-sm gap-1">
        <span class="inline-block size-1.5 animate-pulse rounded-full bg-current"></span>
        working
      </span>
      <span>current turn</span>
      <span class="ml-auto font-mono">{elapsed(@running_since)}</span>
    </div>

    <%!-- Always here, whatever the agent's state (#450). --%>
    <.message_composer
      :if={@subject.kind != :other}
      subject_id={@subject.id}
      state={@subject.state}
      routine={@subject.routine}
      message_gen={@message_gen}
      upload={@upload}
      class="mt-4"
    />
    <p :if={@notice} class="mt-1 text-xs text-base-content/60">{@notice}</p>

    <div role="tablist" class="tabs tabs-border mt-6">
      <button
        :for={tab <- tabs()}
        role="tab"
        phx-click="tab"
        phx-value-tab={tab}
        class={["tab", tab == @tab && "tab-active"]}
      >
        {String.capitalize(tab)}<span :if={tab_count(tab, @subject, @signal)} class="ml-1 font-mono text-xs text-warning">
          {tab_count(tab, @subject, @signal)}
        </span>
      </button>
    </div>

    <div class="mt-4">
      <.attention_tab :if={@tab == "attention"} subject={@subject} signal={@signal} />
      <.activity_tab :if={@tab == "activity"} subject={@subject} />
      <.work_tab :if={@tab == "work"} subject={@subject} message_gen={@message_gen} />
      <.notebook_tab :if={@tab == "notebook"} subject={@subject} />
      <.panel_tab :if={@tab == "panel"} subject={@subject} />
      <.turns_tab :if={@tab == "turns"} subject={@subject} execution={@execution} />
      <.config_tab
        :if={@tab == "config"}
        subject={@subject}
        execution={@execution}
        edit={@edit}
      />
    </div>
    """
  end

  attr(:subject, :map, required: true)
  attr(:signal, :any, required: true)

  defp attention_tab(assigns) do
    ~H"""
    <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
      last said
    </h3>
    <p :if={said(@subject.feed) == []} class="text-sm text-base-content/50">
      nothing yet{sensor_note(@subject.feed)}
    </p>
    <div id="last-said" class="flex flex-col gap-2">
      <.feed_entry :for={entry <- said(@subject.feed)} entry={entry} show_agent={false} />
    </div>

    <.own_read panel={@subject.panel} written_at={panel_written_at(@subject.memories)} />
    <.open_work overview={@subject.overview} />
    """
  end

  attr(:panel, :string, default: nil)
  attr(:written_at, :any, default: nil)

  # The agent's self-curated notes (memory key "panel"): on the live fleet a
  # plan ledger, the untriaged bugs, what is not its work, what to watch. It
  # is the best summary of a subject there is, and it was the last section of
  # the fifth tab.
  defp own_read(assigns) do
    ~H"""
    <section :if={@panel} id="own-read" class="mt-6">
      <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
        agent's own read
        <span class="font-normal normal-case tracking-normal">
          self-curated<span :if={@written_at}>, written <.ago at={@written_at} /></span>
        </span>
      </h3>
      <div class="max-h-96 overflow-y-auto rounded-lg bg-base-100 p-4 shadow-sm">
        <.markdown text={@panel} />
      </div>
    </section>
    """
  end

  defp panel_written_at(memories) do
    case Enum.find(memories, &(&1.key == "panel")) do
      %{updated_at: %DateTime{} = at} -> at
      _none -> nil
    end
  end

  @backlog_shown 5

  attr(:overview, :any, required: true)

  # What is open on the repository, at a glance: every open pull request with
  # its check state, and the top of the backlog. The work tab has all of it.
  # A loading or refused overview draws nothing here; the work tab says why.
  defp open_work(%{overview: %{open_prs: prs, open_issues: issues}} = assigns) do
    assigns =
      assign(assigns,
        prs: prs,
        issues: issues,
        shown: Enum.take(issues.items, @backlog_shown)
      )

    ~H"""
    <section :if={@prs.items != [] or @shown != []} id="open-work" class="mt-6">
      <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
        open work
        <span class="font-normal normal-case tracking-normal">
          {count_label(@prs.total, "pull request")}, {count_label(@issues.total, "issue")}
        </span>
      </h3>
      <div class="rounded-lg bg-base-100 p-3 shadow-sm">
        <.repo_item :for={item <- @prs.items} item={item} />
        <div :if={@prs.items != [] and @shown != []} class="my-2 border-t border-base-200"></div>
        <.repo_item :for={item <- @shown} item={item} />
        <button
          :if={@issues.total > length(@shown)}
          class="link mt-2 text-xs text-base-content/50"
          phx-click="tab"
          phx-value-tab="work"
        >
          All {@issues.total} on the work tab
        </button>
      </div>
    </section>
    """
  end

  defp open_work(assigns), do: ~H""

  # What the AGENT said, not what was said about it: sensor pings, aging
  # notices and inbox drops are all on the activity tab. The feed arrives
  # newest first, so these are its three latest.
  defp said(feed), do: feed |> Custode.Feed.said() |> Enum.take(3)

  defp sensor_note(feed) do
    case Enum.find(feed, &(&1["event"] == "sensor")) do
      %{"summary" => summary} when is_binary(summary) ->
        " from the agent. Last sensor: " <> summary

      _none ->
        ""
    end
  end

  attr(:subject, :map, required: true)

  # Newest first, with each run of identical sensor arrivals drawn once. The
  # "older" button is only offered when the read came back full: a short read
  # means the feed has nothing further back.
  defp activity_tab(assigns) do
    ~H"""
    <p :if={@subject.feed == []} class="text-sm text-base-content/50">no activity yet</p>
    <div id="activity" class="flex flex-col gap-2">
      <.feed_entry
        :for={entry <- Custode.Feed.collapse_repeats(@subject.feed)}
        entry={entry}
        show_agent={false}
        restore_prompt={true}
      />
    </div>
    <button
      :if={length(@subject.feed) >= @subject.feed_limit}
      class="btn btn-ghost btn-sm mt-3"
      phx-click="feed_older"
    >
      Show older
    </button>
    """
  end

  attr(:subject, :map, required: true)
  attr(:message_gen, :integer, required: true)

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
      <WorkflowLaunch.launch_button
        repo={@subject.repo}
        standing={@subject.workflow_gates}
        class="ml-2 inline-block"
      />
      <div class="mt-3"><.repo_overview_panel overview={@subject.overview} /></div>

      <%!-- Take a PR out of the fleet's hands, or give it back (#308). CLI
            only until the console: `mix custode disown`. --%>
      <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50">
        not the fleet's work <span class="font-normal">{length(@subject.disowned)}</span>
      </h3>
      <ul class="mb-3 space-y-1 text-sm">
        <li :for={row <- @subject.disowned} class="flex items-baseline gap-2">
          <a
            href={"https://github.com/#{@subject.repo}/pull/#{row.number}"}
            target="_blank"
            rel="noopener"
            class="link font-mono"
          >
            #{row.number}
          </a>
          <span class="min-w-0 flex-1 text-base-content/70">
            {row.reason || "no reason given"}
            <span class="text-xs text-base-content/40">({row.agent_id})</span>
          </span>
          <button class="btn btn-ghost btn-xs" phx-click="reclaim" phx-value-number={row.number}>
            Reclaim
          </button>
        </li>
      </ul>
      <form
        id={"disown-#{@message_gen}"}
        phx-submit="disown"
        class="flex flex-wrap items-center gap-2"
      >
        <div>
          <label for={"disown-number-#{@message_gen}"} class="mb-1 block text-sm font-medium">Pull request number</label>
          <input
            id={"disown-number-#{@message_gen}"}
            type="text"
            name="number"
            required
            inputmode="numeric"
            aria-describedby={"disown-help-#{@message_gen}"}
            class="input input-bordered input-sm w-32 font-mono"
          />
        </div>
        <div class="min-w-0 flex-1">
          <label for={"disown-reason-#{@message_gen}"} class="mb-1 block text-sm font-medium">Reason (optional)</label>
          <input
            id={"disown-reason-#{@message_gen}"}
            type="text"
            name="reason"
            aria-describedby={"disown-help-#{@message_gen}"}
            class="input input-bordered input-sm w-full"
          />
        </div>
        <button type="submit" class="btn btn-outline btn-sm">Disown</button>
        <p id={"disown-help-#{@message_gen}"} class="w-full text-xs text-base-content/60">Marks this pull request as human-owned. Failing checks will need your attention; agents can read your reason.</p>
      </form>
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
    <ul id="open-todos" class="space-y-1 text-sm">
      <li :for={todo <- @subject.todos} class="group flex items-baseline gap-2">
        <button
          class="btn btn-ghost btn-xs"
          phx-click="todo_done"
          phx-value-todo={todo.id}
          title="Mark done"
        >
          Done
        </button>
        <span class="min-w-0">{todo.text}</span>
      </li>
    </ul>

    <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50">
      memory <span class="font-normal">{length(@subject.memories)}</span>
    </h3>
    <p :if={@subject.memories == []} class="text-sm text-base-content/50">nothing remembered</p>
    <div :for={memory <- @subject.memories} class="group mb-2 flex items-start gap-1 text-sm">
      <span class="font-mono text-xs text-base-content/50">{memory.key}:</span>
      <.foldable_text
        id={"memory-#{memory.id}"}
        text={memory.value}
        class="min-w-0 flex-1"
      />
      <button
        class="btn btn-ghost btn-xs text-base-content/30 opacity-0 group-hover:opacity-100"
        title={"Forget #{memory.key}"}
        phx-click="forget_memory"
        phx-value-key={memory.key}
        data-confirm={"Forget #{memory.key}? The agent will not miss what it cannot recall."}
      >
        Forget
      </button>
    </div>

    <%!-- what the agent finished, not only what it still owes: the open list
          alone cannot say whether last week's queue was worked or dropped --%>
    <details :if={@subject.done_todos != []} id="done-todos" class="mt-3 text-sm">
      <summary class="cursor-pointer text-xs text-base-content/50">
        Done {length(@subject.done_todos)}
      </summary>
      <ul class="mt-1 space-y-1">
        <li :for={todo <- @subject.done_todos} class="flex items-baseline gap-2 text-base-content/60">
          <span class="min-w-0 line-through">{todo.text}</span>
          <span class="ml-auto shrink-0 font-mono text-xs text-base-content/40">
            <.ago at={todo.updated_at} />
          </span>
        </li>
      </ul>
    </details>
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
    <%!-- offered only when the read came back full: a short read means there
          is nothing further back --%>
    <button
      :if={length(@subject.journal) >= @subject.journal_limit}
      class="btn btn-ghost btn-sm mt-3"
      phx-click="journal_older"
    >
      Show older
    </button>
    """
  end

  attr(:subject, :map, required: true)

  # What the agent chose to show about itself (#100): markdown it curates
  # under its own memory key, and HTML it proposed and the operator approved.
  # Agent HTML renders ONLY through `sandboxed_panel/1`.
  defp panel_tab(assigns) do
    ~H"""
    <p
      :if={@subject.panel == nil and @subject.panel_html == nil and @subject.panel_pending == nil}
      class="text-sm text-base-content/50"
    >
      this agent keeps no panel
    </p>

    <section :if={@subject.panel_pending} class="mb-6">
      <div class="mb-2 flex items-center gap-2">
        <h3 class="text-xs font-bold uppercase tracking-widest text-warning">
          proposed panel
        </h3>
        <span class="text-xs text-base-content/50">preview, then decide</span>
        <.action_button variant={:primary} class="ml-auto" phx-click="approve_panel">Approve</.action_button>
        <.action_button variant={:quiet} phx-click="reject_panel">Reject</.action_button>
      </div>
      <.sandboxed_panel html={@subject.panel_pending} />
    </section>

    <section :if={@subject.panel_html} class="mb-6">
      <div class="mb-2 flex items-center gap-2">
        <h3 class="text-xs font-bold uppercase tracking-widest text-base-content/50">panel</h3>
        <button
          :if={@subject.panel_revertable}
          class="btn btn-ghost btn-xs ml-auto"
          phx-click="revert_panel"
          data-confirm="Restore the previous approved panel?"
        >
          Revert
        </button>
      </div>
      <.sandboxed_panel html={@subject.panel_html} />
    </section>

    <section :if={@subject.panel}>
      <h3 class="mb-2 text-xs font-bold uppercase tracking-widest text-base-content/50">
        notes to you <span class="font-normal normal-case">(memory key "panel")</span>
      </h3>
      <.markdown text={@subject.panel} />
    </section>
    """
  end

  attr(:subject, :map, required: true)
  attr(:execution, :map, required: true)

  # Provider jobs are the durable record of the execution contract used by a
  # turn. The process history remains raw below them, but a routine edit must
  # never relabel a live or completed turn with its new defaults.
  defp turns_tab(assigns) do
    assigns =
      assign(
        assigns,
        :reports,
        Enum.filter(assigns.subject.feed, &(&1["report"] || &1["report_error"]))
      )

    ~H"""
    <section :if={@reports != []} id="interval-reports" class="mb-4 space-y-2">
      <h3 class="text-xs font-semibold text-base-content/60">Recent interval reports</h3>
      <.feed_entry :for={entry <- @reports} entry={entry} show_agent={false} />
    </section>
    <p :if={@subject.history == [] and @execution.turns == []} class="text-sm text-base-content/50">
      no machine log: the agent has not run since the node started
    </p>

    <section :if={@execution.turns != []} id="captured-turns" class="mb-4 space-y-2">
      <h3 class="text-xs font-bold uppercase tracking-widest text-base-content/50">
        captured turn configuration
      </h3>
      <div
        :for={turn <- @execution.turns}
        id={"turn-contract-#{turn.id}"}
        data-config-revision={turn.config_revision}
        class="flex flex-wrap items-center gap-2 rounded-lg bg-base-100 px-3 py-2 font-mono text-xs shadow-sm"
      >
        <span class={["badge badge-sm", active_turn?(turn, @execution) && "badge-info"]}>
          {if active_turn?(turn, @execution), do: "active", else: turn.state}
        </span>
        <span>{execution_label(turn)}</span>
        <span class="ml-auto text-base-content/40">turn {short_id(turn.turn_id)}</span>
      </div>
    </section>

    <div
      :if={@subject.history != []}
      class="max-h-[32rem] overflow-y-auto rounded-lg bg-base-100 p-3 font-mono text-xs shadow-sm"
    >
      <p :for={entry <- @subject.history} class="truncate py-0.5 text-base-content/70">
        {inspect(entry, printable_limit: 200)}
      </p>
    </div>
    """
  end

  attr(:subject, :map, required: true)
  attr(:execution, :map, required: true)
  attr(:edit, :any, default: nil)

  defp config_tab(assigns) do
    ~H"""
    <p :if={@subject.routine == nil} class="text-sm text-base-content/50">
      no routine: a sub-agent or a one-shot has no standing configuration
    </p>
    <div :if={@subject.routine} class="space-y-4 text-sm">
      <p class="italic text-base-content/60">{Custode.Roles.summary(@subject.routine.role)}</p>

      <dl class="grid grid-cols-[8rem_1fr] gap-x-4 gap-y-1">
        <dt class="text-base-content/50">role</dt>
        <dd>
          <b>{@subject.routine.role}</b>
          <span class="text-base-content/40">
            ({Custode.Roles.tier(@subject.routine.role)} tier)
          </span>
        </dd>
        <dt :if={current_execution(@execution)} class="text-base-content/50">
          {current_execution_label(@execution)}
        </dt>
        <dd :if={current_execution(@execution)} id="active-turn-config" class="font-mono">
          {execution_label(current_execution(@execution))}
        </dd>
        <dt :if={current_execution(@execution)} class="text-base-content/50">
          {current_execution_label(@execution)} location
        </dt>
        <dd :if={current_execution(@execution)} class="break-all font-mono text-xs">
          {current_execution(@execution).working_dir || "unknown"}
        </dd>
        <dt class="text-base-content/50">
          {if configuration_transition?(@execution), do: "next turn provider", else: "provider"}
        </dt>
        <dd><b>{@subject.routine.provider}</b></dd>
        <dt class="text-base-content/50">
          {if configuration_transition?(@execution), do: "next turn sweeps on", else: "sweeps on"}
        </dt>
        <dd id="desired-turn-config" data-config-revision={@execution.desired.config_revision}>
          <b>{@subject.routine.model || "CLI default"}</b><span :if={@subject.routine.effort}>
            at {@subject.routine.effort} effort
          </span>
        </dd>
        <dt class="text-base-content/50">
          {if configuration_transition?(@execution), do: "next turn location", else: "runs in"}
        </dt>
        <dd class="break-all font-mono text-xs">{@execution.desired.working_dir}</dd>
        <dt :if={@subject.routine.approved_args["model"]} class="text-base-content/50">
          approved work
        </dt>
        <dd :if={@subject.routine.approved_args["model"]}>
          <b>{@subject.routine.approved_args["model"]}</b>
        </dd>
        <dt class="text-base-content/50">schedule</dt>
        <dd class="font-mono">{@subject.routine.cron}</dd>
        <dt class="text-base-content/50">rails</dt>
        <dd>
          ${usd(@subject.routine.max_budget_usd)} a turn<span :if={
            @subject.routine.daily_budget_usd
          }>, ${usd(@subject.routine.daily_budget_usd)} a day</span>
        </dd>
        <dt :if={@subject.routine.repo} class="text-base-content/50">repository</dt>
        <dd :if={@subject.routine.repo} class="font-mono">{@subject.routine.repo}</dd>
        <dt :if={@subject.routine.tags != []} class="text-base-content/50">tags</dt>
        <dd :if={@subject.routine.tags != []}>
          <span :for={tag <- @subject.routine.tags} class="badge badge-ghost badge-sm mr-1">
            {tag}
          </span>
        </dd>
        <dt :if={@subject.sensors != []} class="text-base-content/50">fed by</dt>
        <dd :if={@subject.sensors != []}>
          <span :for={sensor <- @subject.sensors} class="badge badge-outline badge-sm mr-1">
            {sensor.id} ({sensor.cron})
          </span>
        </dd>
        <dt :if={@subject.policies != []} class="text-base-content/50">bound by</dt>
        <dd :if={@subject.policies != []} class="font-mono text-xs">
          {Enum.join(@subject.policies, ", ")}
        </dd>
      </dl>

      <details>
        <summary class="cursor-pointer text-xs text-base-content/50">
          Standing orders (the composed system prompt)
        </summary>
        <pre class="mt-2 max-h-96 overflow-y-auto whitespace-pre-wrap rounded bg-base-100 p-3 text-xs">{@subject.routine.system_prompt}</pre>
      </details>

      <button :if={@edit == nil} class="btn btn-outline btn-sm" phx-click="edit_open">
        Edit
      </button>

      <form
        :if={@edit}
        id="edit-routine"
        phx-change="edit_change"
        phx-submit="edit_save"
        class="rounded-xl border border-base-300 bg-base-100 p-4"
      >
        <p :if={RoutineEdit.migrates?()} class="mb-3 rounded bg-warning/20 p-2 text-xs">
          Saving migrates your roster to <span class="font-mono">routines.toml</span>: from then
          on the file is the roster, and the one in application config is ignored.
        </p>
        <p class="mb-3 text-xs text-base-content/60">
          A blank field clears the override, so the routine inherits its profile or the default
          again. Saved edits are live at the next minute, with no restart.
        </p>
        <div class="grid grid-cols-1 gap-3 md:grid-cols-2">
          <label
            :for={field <- RoutineEdit.fields()}
            class={["form-control", field == "prompt" && "md:col-span-2"]}
          >
            <span class="mb-1 font-mono text-xs text-base-content/60">{field}</span>
            <textarea
              :if={field == "prompt"}
              name={"routine[#{field}]"}
              rows="4"
              class="textarea textarea-bordered w-full text-sm"
            >{@edit.params[field]}</textarea>
            <input
              :if={field != "prompt"}
              type="text"
              name={"routine[#{field}]"}
              value={@edit.params[field]}
              autocomplete="off"
              class="input input-bordered input-sm w-full font-mono"
            />
          </label>
        </div>
        <p :if={@edit.error} class="mt-3 text-xs text-error">{@edit.error}</p>
        <div class="mt-4 flex items-center gap-2">
          <button type="submit" class="btn btn-primary btn-sm">Save</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="edit_close">Cancel</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm ml-auto text-error"
            phx-click="edit_remove"
            data-confirm={"Remove #{@subject.id} from the roster? Its notebook and workspace are kept."}
          >
            Remove from the roster
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp facts(%{kind: :other, attention_item: {:proposal, _id}}, _execution),
    do: "not an agent: a signal with no process behind it"

  defp facts(%{kind: :other, state: :ended}, _execution), do: "ephemeral agent"

  defp facts(%{kind: :other, state: :offline}, _execution),
    do: "no routine or recorded activity"

  defp facts(%{kind: :other}, _execution),
    do: "not an agent: a signal with no process behind it"

  defp facts(%{routine: nil}, _execution), do: "no routine: a sub-agent or a one-shot"

  defp facts(%{routine: routine, spend_today: spend}, execution) do
    [
      routine.role,
      execution_summary(execution),
      routine.cron,
      routine.repo,
      "$#{usd(spend)}" <> budget(routine.daily_budget_usd)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map_join(" · ", &to_string/1)
  end

  defp execution_summary(%{live_error: error}) when not is_nil(error),
    do: "execution unavailable"

  defp execution_summary(execution) do
    execution = current_execution(execution) || execution.desired || %{}

    [
      Map.get(execution, :provider),
      Map.get(execution, :model),
      execution |> Map.get(:effort) |> effort_label()
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp configuration_transition?(%{desired: nil}), do: false

  defp configuration_transition?(%{desired: desired} = execution) do
    applied = current_execution(execution)

    if is_nil(applied) do
      false
    else
      Enum.any?([:provider, :model, :effort, :working_dir, :config_revision], fn key ->
        Map.get(applied, key) != Map.get(desired, key)
      end)
    end
  end

  defp active_turn?(turn, %{active: %{id: id}}), do: turn.id == id
  defp active_turn?(_turn, _execution), do: false

  defp current_execution(%{active: active, applied: applied}), do: active || applied

  defp current_execution_label(%{active: nil}), do: "live process"
  defp current_execution_label(_execution), do: "active turn"

  defp execution_label(nil), do: "execution unknown"

  defp execution_label(execution) do
    [
      execution.provider || "provider unknown",
      execution.model || "model unknown",
      effort_label(execution.effort) || "effort unknown",
      execution_location(execution.working_dir),
      "config #{short_id(execution.config_revision)}"
    ]
    |> Enum.join(" · ")
  end

  defp execution_location(nil), do: "location unknown"
  defp execution_location(path), do: "in #{path}"

  defp effort_label(nil), do: nil
  defp effort_label(effort), do: "#{effort} effort"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 12)
  defp short_id(_id), do: "unknown"

  defp budget(nil), do: " today"
  defp budget(limit), do: " of $#{usd(limit)}"

  defp conversation_facts(arc) do
    session = if arc.provider_session_id, do: "session ready", else: "no provider session"

    "#{arc.kind} arc #{arc.arc_id} · #{arc.decision}/#{arc.reason} · #{session}"
  end

  defp elapsed(%DateTime{} = started_at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s elapsed"
      seconds < 3_600 -> "#{div(seconds, 60)}m#{rem(seconds, 60)}s elapsed"
      true -> "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m elapsed"
    end
  end

  defp note_count(%{note_count: 1}), do: "1 note"
  defp note_count(%{note_count: count}), do: "#{count} notes"

  defp wake_status(%{blocked_by: "debounce"}), do: "debouncing"

  defp wake_status(%{blocked_by: blocked_by}) when blocked_by not in [nil, ""],
    do: "held -- #{wake_blocker(blocked_by)}"

  defp wake_status(%{state: "dispatching"}), do: "dispatching"

  defp wake_status(%{due_at: %DateTime{} = due_at}) do
    if DateTime.compare(due_at, DateTime.utc_now()) == :gt,
      do: "debouncing",
      else: "ready"
  end

  defp wake_status(_wake), do: "ready"

  defp wake_reason("inbox_activity"), do: "inbox activity"
  defp wake_reason(reason), do: reason |> to_string() |> String.replace("_", " ")

  defp wake_blocker("running"), do: "waiting for the current turn"
  defp wake_blocker("awaiting_permission"), do: "approval gate"
  defp wake_blocker("waiting_for_user"), do: "question gate"
  defp wake_blocker("paused"), do: "agent paused"
  defp wake_blocker("spend_rail"), do: "daily spend rail"
  defp wake_blocker("provider_job"), do: "waiting for the previous turn to finish"
  defp wake_blocker("delivery_failed"), do: "delivery failed; waiting for new activity or restart"
  defp wake_blocker("offline"), do: "agent offline"

  defp wake_blocker(blocked_by) do
    blocked_by
    |> to_string()
    |> String.replace("_", " ")
  end

  defp tab_count("attention", _subject, %Signal{} = signal),
    do: if(Signal.needs_you?(signal), do: 1)

  defp tab_count("notebook", %{todos: [_one | _rest] = todos}, _signal), do: length(todos)
  defp tab_count("panel", %{panel_pending: pending}, _signal) when is_binary(pending), do: 1
  defp tab_count(_tab, _subject, _signal), do: nil

  defp count_label(1, noun), do: "1 #{noun}"
  defp count_label(count, noun), do: "#{count} #{noun}s"
end
