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

  import CustodeWeb.Components, only: [host_banner: 1, suggestion_card: 1]
  import CustodeWeb.Console.Header
  import CustodeWeb.Console.Item
  import CustodeWeb.Console.NewAgent
  import CustodeWeb.Console.CommandPalette
  import CustodeWeb.Console.Rail, only: [rail: 1]
  import CustodeWeb.Console.Subject, only: [subject: 1]

  alias Custode.Attention
  alias Custode.Operator.Actions
  alias Custode.Operator.Attachments
  alias Custode.Operator.DirectoryBrowser
  alias Custode.Operator.RoutineEdit
  alias Custode.Operator.RoutineNew
  alias Custode.Signal
  alias CustodeWeb.Console.Commands
  alias CustodeWeb.Console.Rail
  alias CustodeWeb.Console.Subject
  alias CustodeWeb.WorkflowLaunch

  @tabs Subject.tabs()
  @opts [via: :liveview]

  # How many feed entries the subject pane reads, and how many "show older"
  # adds. Sensor pings collapse on the page, so 150 entries is days, not hours.
  @feed_page 150

  # the notebook tab's journal, read this many at a time
  @journal_page 10

  @suggestion_limit 3

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Custode.PubSubBridge.subscribe()
      :timer.send_interval(5_000, self(), :inflight_tick)
    end

    {:ok,
     socket
     |> allow_upload(:image,
       accept: Attachments.image_types(),
       max_entries: 1,
       max_file_size: Attachments.max_bytes()
     )
     |> assign(
       filter: "",
       quiet_open: false,
       away_dismissed: false,
       tab: "attention",
       selected: nil,
       message_gen: 0,
       tell_gen: 0,
       notice: nil,
       fleet_notice: nil,
       edit: nil,
       new_agent: nil,
       setup_skipped: false,
       command_open: false,
       command_query: "",
       command_all: [],
       command_matches: [],
       feed_limit: @feed_page,
       journal_limit: @journal_page,
       checks: %{},
       check_logs: %{}
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(
       selected: params["id"],
       tab: if(params["tab"] in @tabs, do: params["tab"], else: socket.assigns.tab),
       notice: nil,
       edit: nil,
       feed_limit: @feed_page,
       journal_limit: @journal_page,
       checks: %{},
       check_logs: %{}
     )
     |> refresh()
     |> maybe_open_commands(params)
     |> read_checks()}
  end

  # The checks on the pull requests the selected signal points at (#450), read
  # off the page's critical path: the page renders, and each PR's rows arrive
  # when GitHub answers. Only on selection, never on refresh, so a busy feed
  # does not turn into a stream of GitHub reads.
  defp read_checks(
         %{assigns: %{signal: %Signal{item: {:prs, numbers}}, subject: %{repo: repo}}} = socket
       )
       when is_binary(repo) do
    Enum.reduce(numbers, socket, fn number, socket ->
      start_async(socket, {:checks, repo, number}, fn ->
        Custode.Repository.pr_checks(repo, number)
      end)
    end)
  end

  defp read_checks(socket), do: socket

  @impl Phoenix.LiveView
  def handle_async({:checks, repo, number}, {:ok, result}, socket) do
    if selected_pr?(socket, repo, number) do
      case result do
        {:ok, %{checks: checks}} ->
          rows = Enum.sort_by(checks, &check_rank/1)

          socket =
            update(socket, :checks, &Map.put(&1, {repo, number}, {:ok, rows}))

          {:noreply, read_failed_check_logs(socket, repo, number, rows)}

        {:error, reason} ->
          {:noreply,
           update(socket, :checks, &Map.put(&1, {repo, number}, {:error, to_string(reason)}))}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_async({:checks, repo, number}, {:exit, reason}, socket) do
    if selected_pr?(socket, repo, number) do
      {:noreply, update(socket, :checks, &Map.put(&1, {repo, number}, {:error, inspect(reason)}))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:check_log, repo, number, check_id}, {:ok, result}, socket) do
    if selected_pr?(socket, repo, number) do
      log = if match?({:ok, _text}, result), do: result, else: :unavailable

      {:noreply, update(socket, :check_logs, &Map.put(&1, {repo, check_id}, log))}
    else
      {:noreply, socket}
    end
  end

  def handle_async({:check_log, _repo, _number, _check_id}, {:exit, _reason}, socket),
    do: {:noreply, socket}

  defp read_failed_check_logs(socket, repo, number, rows) do
    rows
    |> Enum.filter(&failed_check?/1)
    |> Enum.reduce(socket, fn
      %{id: id}, socket when is_integer(id) ->
        start_async(socket, {:check_log, repo, number, id}, fn ->
          Custode.Repository.job_log_tail(repo, id)
        end)

      _row, socket ->
        socket
    end)
  end

  defp selected_pr?(
         %{assigns: %{signal: %Signal{item: {:prs, numbers}}, subject: %{repo: repo}}},
         repo,
         number
       ),
       do: number in numbers

  defp selected_pr?(_socket, _repo, _number), do: false

  # failed first, then still running, then the rest, each by name
  defp check_rank(%{conclusion: conclusion, name: name})
       when conclusion in ~w(failure timed_out cancelled),
       do: {0, name}

  defp check_rank(%{conclusion: nil, name: name}), do: {1, name}
  defp check_rank(%{name: name}), do: {2, name}

  defp failed_check?(%{conclusion: conclusion}),
    do: conclusion in ~w(failure timed_out cancelled)

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:notebook_changed, _routine_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:repo_overview, _repo}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:usage_changed, _provider}, socket), do: {:noreply, refresh(socket)}

  def handle_info(:inflight_tick, socket),
    do: {:noreply, assign(socket, in_flight: Custode.RunClock.running())}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("filter", %{"q" => q}, socket),
    do: {:noreply, socket |> assign(filter: q) |> refresh()}

  def handle_event("command_open", _params, socket),
    do: {:noreply, open_commands(socket)}

  def handle_event("command_close", _params, socket),
    do: {:noreply, close_commands(socket)}

  def handle_event("command_search", %{"q" => query}, socket) do
    {:noreply,
     assign(socket,
       command_query: query,
       command_matches: Commands.search(socket.assigns.command_all, query)
     )}
  end

  def handle_event("command_select", %{"id" => id}, socket) do
    case Enum.find(socket.assigns.command_all, &(&1.id == id)) do
      %{path: path} when is_binary(path) ->
        {:noreply, socket |> close_commands() |> push_navigate(to: path)}

      %{action: action} when is_atom(action) ->
        run_command(action, close_commands(socket))

      _stale ->
        {:noreply, open_commands(socket)}
    end
  end

  def handle_event("toggle_quiet", _params, socket),
    do: {:noreply, assign(socket, quiet_open: !socket.assigns.quiet_open)}

  # The return digest is a greeting for this browser session. Once dismissed,
  # ordinary fleet updates must not bring the same absence window back.
  def handle_event("dismiss_away_digest", _params, socket),
    do: {:noreply, assign(socket, away_dismissed: true, away_digest: nil)}

  def handle_event("apply_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    case Actions.apply_suggestion(id, field, proposed, @opts) do
      {:ok, message} ->
        {:noreply, socket |> assign(fleet_notice: message) |> refresh()}

      {:error, reason} ->
        {:noreply, assign(socket, fleet_notice: "apply refused: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params
    {:ok, message} = Actions.dismiss_suggestion(id, field, proposed, nil, @opts)
    {:noreply, socket |> assign(fleet_notice: message) |> refresh()}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in @tabs,
    do: {:noreply, assign(socket, tab: tab)}

  # One more page of the selected subject's feed. Reset by handle_params, so
  # a long read of one agent is not carried to the next.
  def handle_event("feed_older", _params, socket),
    do: {:noreply, socket |> update(:feed_limit, &(&1 + @feed_page)) |> refresh()}

  def handle_event("journal_older", _params, socket),
    do: {:noreply, socket |> update(:journal_limit, &(&1 + @journal_page)) |> refresh()}

  # phx-change on the message form: uploads are validated as they are chosen
  def handle_event("validate_message", _params, socket), do: {:noreply, socket}

  def handle_event("drop_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :image, ref)}

  def handle_event("message", %{"text" => text}, socket) do
    # An image alone is a message. The stored paths join the text before it is
    # delivered, so every delivery path (queue, resume, start) carries them.
    text = Attachments.compose(text, save_images(socket))

    case Actions.message(socket.assigns.selected, text, @opts) do
      {:ok, how} ->
        socket = push_event(socket, "draft:clear", %{subject: socket.assigns.selected})
        after_action(:ok, socket, sent_notice(how))

      {:error, reason} ->
        after_action({:error, reason}, socket, nil)
    end
  end

  # Prompt history restores into the browser-owned composer. It does not call
  # an operator action and therefore cannot resend an old instruction.
  def handle_event("restore_message", %{"text" => text}, socket) when is_binary(text) do
    {:noreply,
     push_event(socket, "draft:restore", %{subject: socket.assigns.selected, text: text})}
  end

  # A sentence to the caretaker, from wherever the operator is (#451).
  def handle_event("tell_custode", %{"text" => text}, socket) do
    notice =
      case Actions.tell_custode(text, @opts) do
        {:ok, how} -> "custode: " <> sent_notice(how)
        {:error, :empty} -> nil
        {:error, :no_caretaker} -> "no caretaker: no routine is tagged :meta"
        {:error, reason} -> "custode: failed (#{inspect(reason)})"
      end

    gen = if notice, do: socket.assigns.tell_gen + 1, else: socket.assigns.tell_gen
    {:noreply, socket |> assign(fleet_notice: notice, tell_gen: gen) |> refresh()}
  end

  def handle_event("pause_all", _params, socket) do
    {:ok, ids} = Actions.pause_all(@opts)
    {:noreply, socket |> assign(fleet_notice: "paused #{length(ids)} agent(s)") |> refresh()}
  end

  def handle_event("resume_all", _params, socket) do
    {:ok, ids} = Actions.resume_all(@opts)
    {:noreply, socket |> assign(fleet_notice: "resumed #{length(ids)} agent(s)") |> refresh()}
  end

  def handle_event("toggle_presence", _params, socket) do
    mode = if match?({:present, _at}, socket.assigns.presence), do: :away, else: :auto
    :ok = Actions.set_presence(mode, @opts)
    {:noreply, refresh(socket)}
  end

  # The shared handler, unchanged (design/005): a launch from here opens the
  # same gate as one from /repos, and the gate says where the click came from.
  def handle_event("propose_workflow", params, socket) do
    why = "launched by hand from the console, on #{socket.assigns.selected}"
    {:noreply, socket |> WorkflowLaunch.propose(params, why) |> refresh()}
  end

  def handle_event("disown", %{"number" => number} = params, socket) do
    %{id: agent_id, repo: repo} = socket.assigns.subject

    agent_id
    |> Actions.disown(repo, number, params["reason"], @opts)
    |> after_action(socket, "disowned ##{String.trim_leading(number, "#")}")
  end

  def handle_event("reclaim", %{"number" => number}, socket) do
    socket.assigns.subject.repo
    |> Actions.reclaim(number, @opts)
    |> after_action(socket, "reclaimed ##{number}")
  end

  def handle_event("drain", _params, socket) do
    case Actions.drain(@opts) do
      {:ok, executing} ->
        notice =
          "draining: queues paused, #{executing} turn(s) executing. The node stops when they finish."

        {:noreply, socket |> assign(fleet_notice: notice) |> refresh()}

      {:error, _reason} = error ->
        after_action(error, socket, nil)
    end
  end

  def handle_event("approve_panel", _params, socket),
    do: socket.assigns.selected |> Actions.approve_panel(@opts) |> after_action(socket, nil)

  def handle_event("reject_panel", _params, socket),
    do: socket.assigns.selected |> Actions.reject_panel(@opts) |> after_action(socket, nil)

  def handle_event("revert_panel", _params, socket),
    do: socket.assigns.selected |> Actions.revert_panel(@opts) |> after_action(socket, nil)

  # Adding a routine (#450). The form's conversions and the TOML preview are
  # RoutineNew's; what is previewed is the literal text a create appends.
  def handle_event("new_open", _params, socket),
    do: {:noreply, assign(socket, new_agent: plan_new_agent(RoutineNew.defaults("bespoke")))}

  def handle_event("new_choose", _params, socket),
    do: {:noreply, assign(socket, new_agent: new_agent_state(%{}, choosing: true))}

  def handle_event("new_kind", %{"kind" => kind}, socket),
    do: {:noreply, assign(socket, new_agent: plan_new_agent(RoutineNew.defaults(kind)))}

  def handle_event("new_skip", _params, socket),
    do: {:noreply, assign(socket, new_agent: nil, setup_skipped: true)}

  def handle_event("new_close", _params, socket), do: {:noreply, assign(socket, new_agent: nil)}

  def handle_event("new_change", %{"routine" => params}, socket) do
    {:noreply, assign(socket, new_agent: plan_new_agent(params))}
  end

  def handle_event("new_browse", _params, socket) do
    start = socket.assigns.new_agent.params["working_dir"]
    start = if is_binary(start) and File.dir?(start), do: start

    case DirectoryBrowser.list(start) do
      {:ok, browser} ->
        {:noreply, update(socket, :new_agent, &%{&1 | browser: browser})}

      {:error, reason} ->
        {:noreply,
         update(socket, :new_agent, &%{&1 | error: "cannot browse host: #{inspect(reason)}"})}
    end
  end

  def handle_event("new_browse_dir", %{"path" => path}, socket) do
    case DirectoryBrowser.list(path) do
      {:ok, browser} ->
        {:noreply, update(socket, :new_agent, &%{&1 | browser: browser})}

      {:error, reason} ->
        {:noreply,
         update(socket, :new_agent, &%{&1 | error: "cannot browse host: #{inspect(reason)}"})}
    end
  end

  def handle_event("new_browse_choose", %{"path" => path}, socket) do
    params =
      socket.assigns.new_agent.params
      |> Map.put("working_dir", path)
      |> Map.put("checkout_mode", "existing")

    {:noreply, assign(socket, new_agent: plan_new_agent(params))}
  end

  def handle_event("new_browse_close", _params, socket),
    do: {:noreply, update(socket, :new_agent, &%{&1 | browser: nil})}

  def handle_event("new_create", %{"routine" => params}, socket) do
    case RoutineNew.create(params, surface: "console") do
      {:ok, id} ->
        {:noreply,
         socket
         |> assign(
           new_agent: nil,
           fleet_notice: "#{id} added: live now, scheduled at its next cron minute"
         )
         |> push_patch(to: Rail.subject_path(id))}

      {:error, reason} ->
        error = "refused: " <> if(is_binary(reason), do: reason, else: inspect(reason))
        {:noreply, update(socket, :new_agent, &%{&1 | params: params, error: error})}
    end
  end

  # Editing a routine (#450). The form's rules (blank clears an override, the
  # first value that does not parse refuses the save) are RoutineEdit's.
  def handle_event("edit_open", _params, socket) do
    case RoutineEdit.load(socket.assigns.selected) do
      {:ok, strings} ->
        {:noreply, assign(socket, edit: %{original: strings, params: strings, error: nil})}

      {:error, reason} ->
        {:noreply, assign(socket, notice: "cannot edit: #{inspect(reason)}")}
    end
  end

  def handle_event("edit_close", _params, socket), do: {:noreply, assign(socket, edit: nil)}

  def handle_event("edit_change", %{"routine" => params}, socket),
    do: {:noreply, update(socket, :edit, &%{&1 | params: params})}

  def handle_event("edit_save", %{"routine" => params}, socket) do
    case RoutineEdit.save(socket.assigns.selected, socket.assigns.edit.original, params) do
      {:ok, :unchanged} ->
        {:noreply, socket |> assign(edit: nil, notice: "no changes") |> refresh()}

      {:ok, :saved} ->
        {:noreply,
         socket |> assign(edit: nil, notice: "saved: live at the next minute") |> refresh()}

      {:error, reason} ->
        error = "refused: " <> if(is_binary(reason), do: reason, else: inspect(reason))
        {:noreply, update(socket, :edit, &%{&1 | params: params, error: error})}
    end
  end

  def handle_event("edit_remove", _params, socket) do
    id = socket.assigns.selected

    case RoutineEdit.remove(id, surface: "console") do
      :ok ->
        {:noreply,
         socket
         |> assign(edit: nil, fleet_notice: "#{id} removed: its notebook and workspace are kept")
         |> push_patch(to: "/console")}

      {:error, reason} ->
        {:noreply, update(socket, :edit, &%{&1 | error: "remove refused: #{inspect(reason)}"})}
    end
  end

  def handle_event("drop_draft", %{"id" => id}, socket),
    do: id |> Actions.drop_draft(@opts) |> after_action(socket, nil)

  def handle_event("keep_draft", %{"id" => id}, socket),
    do: id |> Actions.keep_draft(@opts) |> after_action(socket, nil)

  def handle_event("todo_done", %{"todo" => id}, socket),
    do: id |> Actions.complete_todo(@opts) |> after_action(socket, nil)

  def handle_event("forget_memory", %{"key" => key}, socket) do
    socket.assigns.selected
    |> Actions.forget_memory(key, @opts)
    |> after_action(socket, nil)
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
      notice = if atom == :dismiss_ask, do: "dismissed", else: to_string(atom)
      atom |> Actions.run(args, params, @opts) |> after_action(socket, notice)
    else
      _stale -> {:noreply, socket |> assign(notice: "that is no longer pending") |> refresh()}
    end
  end

  # One of the agent's own suggested answers (#450). The client sends an index
  # and nothing else: the text comes from the selected signal, so this path
  # can only ever send what the agent offered.
  def handle_event("reply", %{"index" => index}, socket) do
    with %Signal{resolving: resolving} <- socket.assigns.signal,
         %{args: %{replies: replies} = args} <- Enum.find(resolving, &(&1.op == :answer_ask)),
         {position, ""} <- Integer.parse(index),
         reply when is_binary(reply) <- Enum.at(replies, position) do
      :answer_ask
      |> Actions.run(args, %{"text" => reply}, @opts)
      |> after_action(socket, "answered")
    else
      _stale -> {:noreply, socket |> assign(notice: "that is no longer pending") |> refresh()}
    end
  end

  # A subject with no routine has no workspace to put an image in.
  defp save_images(%{assigns: %{subject: %{routine: %{} = routine}}} = socket) do
    consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
      {:ok, Attachments.store!(routine, path, entry.client_name)}
    end)
  end

  defp save_images(_socket), do: []

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
      <.console_header
        caretaker={@caretaker}
        tell_gen={@tell_gen}
        presence={@presence}
        usage={@usage}
        attention_signals={@attention_signals}
        fleet_today={@fleet_today}
        notice={@fleet_notice}
        selected={@selected}
        signal={@signal}
      />

      <.command_palette
        open={@command_open}
        query={@command_query}
        commands={@command_matches}
      />

      <div class="px-5 pt-4 empty:hidden"><.host_banner /></div>

      <div class="grid flex-1 grid-cols-1 md:grid-cols-[17rem_1fr] xl:grid-cols-[17rem_1fr_24rem]">
        <.rail
          groups={@groups}
          selected={@selected}
          caretaker={@caretaker}
          filter={@filter}
          in_flight={@in_flight}
          quiet_open={@quiet_open}
        />

        <main class="min-w-0 border-base-300 p-6 md:border-l">
          <div
            :if={@away_digest}
            id="away-digest"
            class="mb-6 rounded-lg border border-info/30 bg-info/5 p-3"
          >
            <div class="mb-2 flex items-center gap-2">
              <span class="text-xs font-semibold text-info">while you were away</span>
              <button class="btn btn-ghost btn-xs ml-auto" phx-click="dismiss_away_digest">
                dismiss
              </button>
            </div>
            <pre class="max-h-64 overflow-auto whitespace-pre-wrap text-xs text-base-content/80">{@away_digest}</pre>
          </div>
          <.new_agent_form :if={@new_agent} new_agent={@new_agent} />
          <p
            :if={@subject == nil and @new_agent == nil and not @roster_empty}
            class="text-base-content/50"
          >
            Pick a subject from the rail.
          </p>
          <%!-- A fresh checkout has no roster of its own (#530). Keyed on the
                roster and not on the rail: an agent with no routine behind it
                (a sub-agent, a one-shot) can be in the rail of a machine that
                still has nothing configured. --%>
          <div
            :if={@roster_empty and @new_agent == nil and @setup_skipped}
            id="empty-fleet"
            class="mb-6 max-w-prose text-sm text-base-content/70"
          >
            <p class="font-semibold text-base-content">No agents on this machine yet.</p>
            <p class="mt-2">
              The fleet is local: a routine names a repository and a checkout of it here.
              Add one with <span class="font-mono">new agent</span>
              in the rail, or copy <span class="font-mono">routines.example.toml</span>
              to <span class="font-mono">routines.toml</span>
              and restart.
            </p>
          </div>
          <.new_agent_form
            :if={@roster_empty and @new_agent == nil and not @setup_skipped}
            new_agent={new_agent_state(%{}, choosing: true)}
          />
          <div
            :if={not @roster_empty and @caretaker_missing and @new_agent == nil}
            id="caretaker-setup"
            class="mb-6 rounded-lg border border-warning/30 bg-warning/5 p-4"
          >
            <p class="font-semibold">This fleet has no valid caretaker.</p>
            <p class="mt-1 text-sm text-base-content/60">
              Add the fixed caretaker role to make the Custode surface available.
            </p>
            <button class="btn btn-primary btn-sm mt-3" phx-click="new_kind" phx-value-kind="caretaker">
              set up caretaker
            </button>
          </div>
          <.subject
            :if={@subject && @new_agent == nil}
            subject={@subject}
            signal={@signal}
            tab={@tab}
            notice={@notice}
            message_gen={@message_gen}
            edit={@edit}
            upload={@uploads.image}
            running_since={Map.get(@in_flight, @subject.id)}
          />
        </main>

        <%!-- under the subject at medium widths, its own column when there is room --%>
        <aside class="border-base-300 bg-base-100 p-6 md:col-start-2 md:border-l md:border-t xl:col-start-auto xl:border-t-0">
          <.item
            :if={@subject}
            signal={@signal}
            subject={@subject}
            message_gen={@message_gen}
            next_up={@next_up}
            checks={@checks}
            check_logs={@check_logs}
          />
          <section :if={@suggestions != []} id="advisor-suggestions" class="mt-6 flex flex-col gap-2">
            <div class="flex items-baseline gap-2">
              <h2 class="text-xs font-bold uppercase tracking-widest text-base-content/50">
                suggestions
              </h2>
              <.link navigate="/suggestions" class="ml-auto text-xs text-primary hover:underline">
                see all {@suggestion_count} &rarr;
              </.link>
            </div>
            <.suggestion_card
              :for={suggestion <- @suggestions}
              suggestion={suggestion}
              agent_base="/console/"
            />
          </section>
        </aside>
      </div>
    </div>
    """
  end

  # -- data -------------------------------------------------------------------

  defp away_digest(%{assigns: %{away_dismissed: true}}), do: nil

  defp away_digest(_socket) do
    case Custode.Presence.away_window() do
      {:since, since} -> since |> Custode.Digest.build_since() |> Custode.Digest.to_markdown()
      :none -> nil
    end
  end

  defp refresh(socket) do
    filter = socket.assigns.filter |> String.trim() |> String.downcase()

    # The host signal (#443) has no agent of its own and is drawn as the
    # banner, so it stays out of a rail of subjects.
    attention_signals = Attention.Fleet.signals()
    signals = Enum.reject(attention_signals, &(&1.kind == :host_down))

    groups =
      signals
      |> Enum.filter(&(filter == "" or String.contains?(haystack(&1), filter)))
      |> Attention.by_group()

    selected = socket.assigns.selected || default_selection(signals)
    signal = Enum.find(signals, &(&1.subject == selected)) || fallback_signal(selected)

    standing_suggestions = Custode.Suggestions.standing()

    assign(socket,
      groups: groups,
      signals: signals,
      attention_signals: attention_signals,
      selected: selected,
      signal: signal,
      subject:
        signal &&
          load_subject(selected, signal, socket.assigns.feed_limit, socket.assigns.journal_limit),
      in_flight: Custode.RunClock.running(),
      roster_empty: Custode.Routine.all() == [],
      caretaker_missing: not Enum.any?(Custode.Routine.all(), &(&1.role == :caretaker)),
      # already ranked by the resolver, so the first one that is not on screen
      # is the next one
      next_up: Enum.find(signals, &(Signal.needs_you?(&1) and &1.subject != selected)),
      fleet_today: Custode.SpendLedger.fleet_today(),
      usage: Custode.Availability.usage("claude"),
      caretaker: Actions.caretaker(),
      presence: Custode.Presence.status(),
      away_digest: away_digest(socket),
      suggestions: Enum.take(standing_suggestions, @suggestion_limit),
      suggestion_count: length(standing_suggestions)
    )
  end

  defp maybe_open_commands(socket, %{"commands" => "open"}), do: open_commands(socket)
  defp maybe_open_commands(socket, _params), do: socket

  defp open_commands(socket) do
    commands = Commands.all(socket.assigns.signals, socket.assigns.selected)

    assign(socket,
      command_open: true,
      command_query: "",
      command_all: commands,
      command_matches: Commands.search(commands, "")
    )
  end

  defp close_commands(socket) do
    assign(socket,
      command_open: false,
      command_query: "",
      command_all: [],
      command_matches: []
    )
  end

  defp run_command(:new_agent, socket),
    do: {:noreply, assign(socket, new_agent: plan_new_agent(RoutineNew.defaults("bespoke")))}

  defp run_command(:beat, socket),
    do: socket.assigns.selected |> Actions.beat(@opts) |> after_action(socket, "beat queued")

  defp run_command(:pause, socket),
    do: socket.assigns.selected |> Actions.pause(@opts) |> after_action(socket, "paused")

  defp run_command(:resume, socket),
    do: socket.assigns.selected |> Actions.resume(@opts) |> after_action(socket, "resumed")

  defp plan_new_agent(params) do
    case RoutineNew.plan(params) do
      {:ok, plan} -> new_agent_state(params, plan: plan)
      {:error, message} -> new_agent_state(params, error: message)
    end
  end

  defp new_agent_state(params, opts) do
    %{
      params: params,
      plan: Keyword.get(opts, :plan),
      preview: Keyword.get(opts, :plan) && Keyword.fetch!(opts, :plan).toml,
      error: Keyword.get(opts, :error),
      browser: Keyword.get(opts, :browser),
      choosing: Keyword.get(opts, :choosing, false)
    }
  end

  # What the rail filter matches: the subject's id, and for a routine its
  # repository, role and tags, so "rust", "external" or an owner name narrows
  # the rail the way a tag filter would. The headline too: "gate" or "red"
  # finds everything in that state.
  defp haystack(%Signal{subject: id, headline: headline}) do
    routine = Custode.Routine.get(id)

    [id, headline, routine && routine.repo, routine && Map.get(routine, :profile)]
    |> Enum.concat((routine && Map.get(routine, :tags)) || [])
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" ", &to_string/1)
    |> String.downcase()
  end

  # What most needs the operator is the right thing to open on.
  defp default_selection([first | _rest]), do: first.subject
  defp default_selection([]), do: nil

  defp load_subject(id, signal, feed_limit, journal_limit) do
    routine = Custode.Routine.get(id)
    {:ok, status} = Custode.Agents.status(id)
    state = status |> Custode.state_of() |> resolve_subject_state(routine, id)
    status = if state == Custode.state_of(status), do: status, else: state
    repo = routine && routine.repo

    %{
      id: id,
      routine: routine,
      kind: subject_kind(routine, state),
      status: status,
      state: state,
      attention_item: Map.get(signal, :item),
      repo: repo,
      overview: repo && overview(repo),
      workflow_gates: (repo && WorkflowLaunch.standing_for(repo)) || %{},
      disowned: disowned(repo),
      spend_today: Custode.SpendLedger.today(id),
      # newest first: the store reads oldest first, and both tabs that draw it
      # lead with what just happened
      feed: id |> Custode.Feed.for_agent(feed_limit) |> Enum.reverse(),
      feed_limit: feed_limit,
      todos: Custode.Notebook.todos(id),
      journal: Custode.Notebook.journal(id, journal_limit),
      journal_limit: journal_limit,
      # newest first, and bounded: a long-lived agent has hundreds
      done_todos: id |> Custode.Notebook.todos("done") |> Enum.take(-20) |> Enum.reverse(),
      panel: panel_markdown(id),
      panel_html: Custode.Panels.current(id),
      panel_pending: Custode.Panels.pending(id),
      panel_revertable: Custode.Panels.revertable?(id),
      draft_batch: Custode.Drafts.pending_batch(id),
      memories: Custode.Memory.recall(id),
      history: history(id),
      sensors: Enum.filter(Custode.Routine.sensors(), &(&1.notify == id)),
      policies: (routine && Custode.Policy.ids_for(routine)) || [],
      conversation: Custode.ConversationArcs.read_model(id)
    }
  end

  defp disowned(nil), do: []
  defp disowned(repo), do: Enum.filter(Custode.Disowned.all(), &(&1.repo == repo))

  defp panel_markdown(id) do
    case Custode.Memory.recall(id, "panel") do
      {:ok, markdown} -> markdown
      :error -> nil
    end
  end

  defp history(id) do
    case Custode.Agents.history(id) do
      {:ok, history} -> history |> Enum.take(-40) |> Enum.reverse()
      {:error, _reason} -> []
    end
  end

  # A routine has a beat. A live process with no routine (a sub-agent, a
  # one-shot) can be paused and spoken to. Anything else is a signal with no
  # agent behind it, such as a workflow launch (#447), and gets no controls.
  defp subject_kind(%{} = _routine, _state), do: :routine
  defp subject_kind(nil, state) when state in [:offline, :ended], do: :other
  defp subject_kind(nil, _state), do: :agent

  defp resolve_subject_state(:offline, nil, id) do
    if Custode.Feed.last_activity_at(id), do: :ended, else: :offline
  end

  defp resolve_subject_state(state, _routine, _id), do: state

  defp fallback_signal(nil), do: nil

  defp fallback_signal(id) do
    %Signal{
      subject: id,
      kind: :quiet,
      group: :quiet,
      urgency: :low,
      headline: "No current attention item",
      detail: "This bookmarked subject is not in the active rail."
    }
  end

  # `{:error, reason}` passes through as it is (#485): the work tab's panel
  # draws the reason where the overview would be.
  defp overview(repo) do
    case Custode.GitHub.overview(repo) do
      {:ok, overview} -> overview
      :loading -> :loading
      {:error, reason} -> {:error, reason}
    end
  end
end
