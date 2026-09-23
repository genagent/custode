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
    ~H"""
    <div class="flex flex-wrap items-center gap-3">
      <h1 class="font-mono text-2xl font-bold">{@subject.id}</h1>
      <.status_badge status={@subject.status} />
      <%!-- A subject is not always an agent: a workflow signal has nothing to
            beat, pause or talk to. Only a routine has a beat. --%>
      <div :if={@subject.kind != :other} class="ml-auto flex gap-2">
        <button :if={@subject.kind == :routine} class="btn btn-outline btn-sm" phx-click="beat">
          beat now
        </button>
        <button :if={@subject.state != :paused} class="btn btn-outline btn-sm" phx-click="pause">
          pause
        </button>
        <button :if={@subject.state == :paused} class="btn btn-outline btn-sm" phx-click="resume">
          resume
        </button>
      </div>
    </div>

    <p class="mt-1 font-mono text-xs text-base-content/60">{facts(@subject)}</p>
    <p :if={@subject.state == :offline} class="mt-2 text-sm text-base-content/50">
      offline -- the next beat starts it
    </p>
    <p :if={@subject.state == :ended} class="mt-2 text-sm text-base-content/50">
      ended -- this was an ephemeral agent; its memory and activity remain available here
    </p>

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

    <%!-- Always here, whatever the agent's state (#450). The button says
          what sending will do: queue, answer, resume first, or start a turn. --%>
    <form
      :if={@subject.kind != :other}
      id={"message-#{@message_gen}"}
      phx-hook="SubjectDraft"
      phx-submit="message"
      phx-change="validate_message"
      data-subject-draft
      data-subject={@subject.id}
      class="mt-4"
    >
      <div :for={entry <- @upload.entries} class="mb-1 flex items-center gap-2 text-xs">
        <span class="badge badge-ghost badge-sm font-mono">{entry.client_name}</span>
        <button
          type="button"
          class="link text-base-content/50"
          phx-click="drop_image"
          phx-value-ref={entry.ref}
        >
          remove
        </button>
        <span :for={error <- upload_errors(@upload, entry)} class="text-error">
          {upload_error_text(error)}
        </span>
      </div>
      <p :for={error <- upload_errors(@upload)} class="mb-1 text-xs text-error">
        {upload_error_text(error)}
      </p>

      <div class="flex gap-2" phx-drop-target={@subject.routine && @upload.ref}>
        <textarea
          name="text"
          rows="2"
          data-draft-input
          class="textarea textarea-bordered w-full text-sm"
          placeholder={"message #{@subject.id}... #{message_hint(@subject.state)}"}
        ></textarea>
        <button
          type="submit"
          class="btn btn-primary btn-sm self-end"
          phx-disable-with="sending..."
        >
          {message_label(@subject.state)}
        </button>
      </div>

      <div class="mt-1 flex items-center gap-2 text-xs text-base-content/50">
        <span data-draft-state hidden>unsent draft saved in this browser</span>
        <button type="button" data-discard-draft hidden class="link">discard draft</button>
      </div>

      <%!-- An image reaches the agent as a path in its own workspace (#180),
            so a subject with no routine has nowhere to put one. --%>
      <label
        :if={@subject.routine}
        class="mt-1 flex items-center gap-2 text-xs text-base-content/40"
      >
        <.live_file_input upload={@upload} class="file-input file-input-xs w-52" />
        or drop an image on the box
      </label>
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
      <.work_tab :if={@tab == "work"} subject={@subject} message_gen={@message_gen} />
      <.notebook_tab :if={@tab == "notebook"} subject={@subject} />
      <.panel_tab :if={@tab == "panel"} subject={@subject} />
      <.turns_tab :if={@tab == "turns"} subject={@subject} />
      <.config_tab :if={@tab == "config"} subject={@subject} edit={@edit} />
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
          {@prs.total} pull request(s), {@issues.total} issue(s)
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
          all {@issues.total} on the work tab
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
      show older
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
            reclaim
          </button>
        </li>
      </ul>
      <form
        id={"disown-#{@message_gen}"}
        phx-submit="disown"
        class="flex flex-wrap items-center gap-2"
      >
        <input
          type="text"
          name="number"
          required
          inputmode="numeric"
          placeholder="PR #"
          class="input input-bordered input-sm w-24 font-mono"
        />
        <input
          type="text"
          name="reason"
          placeholder="why it is yours (the agents read this)"
          class="input input-bordered input-sm min-w-0 flex-1"
        />
        <button type="submit" class="btn btn-outline btn-sm">disown</button>
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
          title="mark done"
        >
          done
        </button>
        <span class="min-w-0">{todo.text}</span>
      </li>
    </ul>

    <h3 class="mb-2 mt-6 text-xs font-bold uppercase tracking-widest text-base-content/50">
      memory <span class="font-normal">{length(@subject.memories)}</span>
    </h3>
    <p :if={@subject.memories == []} class="text-sm text-base-content/50">nothing remembered</p>
    <div :for={memory <- @subject.memories} class="group mb-1 flex items-baseline gap-1 text-sm">
      <span class="font-mono text-xs text-base-content/50">{memory.key}:</span>
      <span class="min-w-0 break-words">{memory.value}</span>
      <button
        class="btn btn-ghost btn-xs text-base-content/30 opacity-0 group-hover:opacity-100"
        title={"forget #{memory.key}"}
        phx-click="forget_memory"
        phx-value-key={memory.key}
        data-confirm={"forget #{memory.key}? The agent will not miss what it cannot recall."}
      >
        forget
      </button>
    </div>

    <%!-- what the agent finished, not only what it still owes: the open list
          alone cannot say whether last week's queue was worked or dropped --%>
    <details :if={@subject.done_todos != []} id="done-todos" class="mt-3 text-sm">
      <summary class="cursor-pointer text-xs text-base-content/50">
        done {length(@subject.done_todos)}
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
      show older
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
        <button class="btn btn-success btn-xs ml-auto" phx-click="approve_panel">approve</button>
        <button class="btn btn-ghost btn-xs" phx-click="reject_panel">reject</button>
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
          revert
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

  # The engine's own record of what the agent process did, newest first. Raw
  # on purpose: this is the tab for "what actually happened", and a prettier
  # rendering would be a second opinion about it.
  defp turns_tab(assigns) do
    ~H"""
    <p :if={@subject.history == []} class="text-sm text-base-content/50">
      no machine log: the agent has not run since the node started
    </p>
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
        <dt class="text-base-content/50">provider</dt>
        <dd><b>{@subject.routine.provider}</b></dd>
        <dt class="text-base-content/50">sweeps on</dt>
        <dd>
          <b>{@subject.routine.model || "CLI default"}</b><span :if={@subject.routine.effort}>
            at {@subject.routine.effort} effort
          </span>
        </dd>
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
          standing orders (the composed system prompt)
        </summary>
        <pre class="mt-2 max-h-96 overflow-y-auto whitespace-pre-wrap rounded bg-base-100 p-3 text-xs">{@subject.routine.system_prompt}</pre>
      </details>

      <button :if={@edit == nil} class="btn btn-outline btn-sm" phx-click="edit_open">
        edit
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
          <button type="submit" class="btn btn-primary btn-sm">save</button>
          <button type="button" class="btn btn-ghost btn-sm" phx-click="edit_close">cancel</button>
          <button
            type="button"
            class="btn btn-ghost btn-sm ml-auto text-error"
            phx-click="edit_remove"
            data-confirm={"Remove #{@subject.id} from the roster? Its notebook and workspace are kept."}
          >
            remove from the roster
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp facts(%{kind: :other, attention_item: {:proposal, _id}}),
    do: "not an agent: a signal with no process behind it"

  defp facts(%{kind: :other, state: :ended}), do: "ephemeral agent"
  defp facts(%{kind: :other, state: :offline}), do: "no routine or recorded activity"
  defp facts(%{kind: :other}), do: "not an agent: a signal with no process behind it"
  defp facts(%{routine: nil}), do: "no routine: a sub-agent or a one-shot"

  defp facts(%{routine: routine, spend_today: spend}) do
    [
      routine.role,
      routine.provider,
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

  defp elapsed(%DateTime{} = started_at) do
    seconds = max(DateTime.diff(DateTime.utc_now(), started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s elapsed"
      seconds < 3_600 -> "#{div(seconds, 60)}m#{rem(seconds, 60)}s elapsed"
      true -> "#{div(seconds, 3_600)}h#{div(rem(seconds, 3_600), 60)}m elapsed"
    end
  end

  defp upload_error_text(:too_large), do: "too large (10MB max)"
  defp upload_error_text(:too_many_files), do: "one image at a time"
  defp upload_error_text(:not_accepted), do: "not an image type custode accepts"
  defp upload_error_text(other), do: to_string(other)

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
  defp tab_count("panel", %{panel_pending: pending}, _signal) when is_binary(pending), do: 1
  defp tab_count(_tab, _subject, _signal), do: nil

  defp signal_frame(%Signal{kind: kind})
       when kind in [:red_main, :turn_failing, :rail_hit, :disowned_check],
       do: "border-error/40 bg-error/5"

  defp signal_frame(%Signal{group: :needs_you}), do: "border-warning/50 bg-warning/5"
  defp signal_frame(%Signal{}), do: "border-base-300/60"
end
