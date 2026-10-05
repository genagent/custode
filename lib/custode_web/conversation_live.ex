defmodule CustodeWeb.ConversationLive do
  @moduledoc """
  A focused, provider-neutral conversation with one agent.

  The transcript is the durable `Custode.OperatorMessage` projection. Provider
  transcripts stay opaque. Recorded interval updates share the readable
  timeline; raw sensors and operational activity stay in the control room.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components,
    only: [
      ago: 1,
      app_header: 1,
      host_banner: 1,
      markdown: 1,
      interval_report: 1,
      message_content: 1,
      status_badge: 1,
      status_token: 1
    ]

  import CustodeWeb.Console.Composer, only: [message_composer: 1]
  import CustodeWeb.Console.Item, only: [conversation_actions: 1]

  alias Custode.Agents
  alias Custode.Attention.Fleet
  alias Custode.ConversationTimeline
  alias Custode.ExecutionFacts
  alias Custode.Operator.Actions
  alias Custode.Operator.Attachments
  alias Custode.Routine
  alias Custode.Signal
  alias Custode.SpendLedger
  alias CustodeWeb.AttentionSnapshot
  alias CustodeWeb.Console.Rail
  alias CustodeWeb.ManagerPanel

  @page_size 20
  @opts [via: :liveview]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    {:ok,
     socket
     |> allow_upload(:image,
       accept: Attachments.image_types(),
       max_entries: 1,
       max_file_size: Attachments.max_bytes()
     )
     |> assign(
       agent_id: nil,
       manager: false,
       manager_context: nil,
       subject: nil,
       current_run: nil,
       signal: nil,
       pending_exchange_id: nil,
       exchanges: [],
       updates: [],
       timeline_items: [],
       show_updates: true,
       before: nil,
       has_older: false,
       prepend_generation: 0,
       message_gen: 0,
       notice: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _uri, %{assigns: %{live_action: :manager}} = socket) do
    {:noreply,
     socket
     |> assign(manager: true, agent_id: Actions.caretaker(), notice: nil)
     |> load_initial()}
  end

  def handle_params(%{"id" => agent_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(manager: false, manager_context: nil, agent_id: agent_id, notice: nil)
     |> load_initial()}
  end

  @impl Phoenix.LiveView
  def handle_info(
        {:operator_message_changed, agent_id},
        %{assigns: %{agent_id: agent_id}} = socket
      ),
      do: {:noreply, refresh_latest(socket)}

  def handle_info({:feed_entry, %{"agent" => agent}}, %{assigns: %{agent_id: agent}} = socket),
    do: {:noreply, refresh_latest(socket)}

  def handle_info({:status_changed, agent_id}, %{assigns: %{agent_id: agent_id}} = socket),
    do: {:noreply, refresh_entry(socket)}

  def handle_info({event, _payload}, %{assigns: %{manager: true}} = socket)
      when event in [:status_changed, :feed_entry],
      do: {:noreply, refresh_entry(socket)}

  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl Phoenix.LiveView
  def handle_event("older", _params, %{assigns: %{agent_id: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("older", _params, socket) do
    case ConversationTimeline.page(socket.assigns.agent_id,
           limit: @page_size,
           before: socket.assigns.before
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(
           exchanges: merge_exchanges(page.exchanges, socket.assigns.exchanges),
           updates: merge_updates(socket.assigns.updates, page.updates),
           before: page.before,
           has_older: page.has_older,
           prepend_generation: socket.assigns.prepend_generation + 1
         )
         |> refresh_timeline()}

      {:error, _reason} ->
        {:noreply, assign(socket, notice: "older conversation history is unavailable")}
    end
  end

  def handle_event("toggle_updates", _params, socket),
    do: {:noreply, assign(socket, show_updates: not socket.assigns.show_updates)}

  def handle_event("validate_message", _params, socket), do: {:noreply, socket}

  def handle_event("drop_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :image, ref)}

  def handle_event("message", _params, %{assigns: %{agent_id: nil}} = socket),
    do: {:noreply, assign(socket, notice: "set up a caretaker before sending")}

  def handle_event("message", %{"text" => text}, socket) do
    text = Attachments.compose(text, save_images(socket))

    case Actions.message(socket.assigns.agent_id, text, @opts) do
      {:ok, how} ->
        socket = push_event(socket, "draft:clear", %{subject: socket.assigns.agent_id})
        after_action(:ok, socket, sent_notice(how))

      {:error, reason} ->
        after_action({:error, reason}, socket, nil)
    end
  end

  def handle_event(
        "try",
        %{"sentence" => sentence},
        %{assigns: %{manager: true, agent_id: id}} = socket
      )
      when is_binary(id) do
    if ManagerPanel.quick_prompt?(sentence),
      do: {:noreply, push_event(socket, "draft:restore", %{subject: id, text: sentence})},
      else: {:noreply, socket}
  end

  def handle_event("try", _params, socket), do: {:noreply, socket}

  def handle_event("do_it", params, socket) do
    case current_manager_plan(socket, params["action"]) do
      {:ok, agent, action} ->
        agent
        |> Actions.approve(action, @opts)
        |> after_action(socket, "approved: custode is doing it")

      _stale ->
        after_action({:error, :no_longer_pending}, socket, nil)
    end
  end

  def handle_event("recover_plan", params, socket) do
    case current_manager_plan(socket, params["action"]) do
      {:ok, agent, action} ->
        agent
        |> Actions.recover_gate(action, @opts)
        |> after_action(socket, "approval requeued for agent re-evaluation")

      _stale ->
        after_action({:error, :no_longer_pending}, socket, nil)
    end
  end

  def handle_event("reject", params, %{assigns: %{manager: true}} = socket) do
    with {:ok, agent, action} <- current_manager_plan(socket, params["action"]),
         true <- params["agent"] == agent do
      :reject
      |> Actions.run(%{agent: agent, action: action}, params, @opts)
      |> after_action(socket, "cancelled")
    else
      _stale -> after_action({:error, :no_longer_pending}, socket, nil)
    end
  end

  def handle_event("reject", %{"agent" => agent, "action" => action} = params, socket) do
    :reject
    |> Actions.run(%{agent: agent, action: action}, params, @opts)
    |> after_action(socket, "rejected")
  end

  def handle_event("op", %{"op" => op}, %{assigns: %{manager: true}} = socket)
      when op in ["approve", "reject"] do
    after_action({:error, :no_longer_pending}, socket, nil)
  end

  def handle_event("op", %{"op" => op} = params, socket) do
    with %Signal{resolving: resolving} <- socket.assigns.signal,
         %{op: atom, args: args} <- Enum.find(resolving, &(to_string(&1.op) == op)) do
      atom
      |> Actions.run(args, params, @opts)
      |> after_action(socket, action_notice(atom))
    else
      _stale -> after_action({:error, :no_longer_pending}, socket, nil)
    end
  end

  def handle_event("reply", %{"index" => index}, socket) do
    with %Signal{resolving: resolving} <- socket.assigns.signal,
         %{args: %{replies: replies} = args} <- Enum.find(resolving, &(&1.op == :answer_ask)),
         {position, ""} <- Integer.parse(index),
         reply when is_binary(reply) <- Enum.at(replies, position) do
      :answer_ask
      |> Actions.run(args, %{"text" => reply}, @opts)
      |> after_action(socket, "answered")
    else
      _stale -> after_action({:error, :no_longer_pending}, socket, nil)
    end
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <div class="flex h-screen min-h-0 flex-col bg-base-200">
      <.app_header
        active={if @manager, do: :custode, else: :console}
        fleet_today={@fleet_today}
        attention_signals={@attention_signals}
      />
      <header class="shrink-0 border-b border-base-300 bg-base-100 px-4 py-3 sm:px-6">
        <div class="mx-auto flex max-w-5xl flex-wrap items-center gap-x-3 gap-y-1">
          <.link
            navigate={if @agent_id, do: Rail.subject_path(@agent_id), else: "/console"}
            class="link text-xs font-semibold text-base-content/60"
          >
            &larr; control room
          </.link>
          <.link navigate="/subjects" class="link text-xs">Outputs</.link>
          <a :if={@manager} href="#project-report-digest" class="link text-xs">Project digest</a>
          <.link :if={@agent_id} navigate={"/contexts/" <> URI.encode_www_form(@agent_id)} class="link text-xs">Run context</.link>
          <span class="text-base-content/30">/</span>
          <h1 class="font-mono text-lg font-bold">{if @manager, do: "Ask custode", else: @agent_id}</h1>
          <span :if={@manager && @agent_id} class="text-xs text-base-content/60">{@agent_id}</span>
          <.status_badge :if={@subject} status={@subject.status} />
          <button :if={@subject} id="conversation-updates-toggle" type="button"
            phx-click="toggle_updates" aria-pressed={to_string(@show_updates)}
            class="btn btn-ghost btn-sm">Updates {if @show_updates, do: "on", else: "off"}</button>
          <p :if={@subject} class="ml-auto font-mono text-xs text-base-content/50">
            {execution_label(@subject)}
          </p>
          <.link :if={@manager} navigate="/" class="link text-xs text-base-content/50">Close (Esc)</.link>
        </div>
      </header>

      <div :if={@manager} class="shrink-0 empty:hidden px-4 pt-3 sm:px-6"><.host_banner /></div>
      <div :if={@manager && @manager_context.plan} class="max-h-[35vh] shrink-0 overflow-y-auto px-4 py-3 sm:px-6">
        <ManagerPanel.plan plan={@manager_context.plan} caretaker={@agent_id} recovery={@manager_context.recovery} />
      </div>

      <div :if={@current_run} class="shrink-0 px-4 py-2 sm:px-6">
        <div class="mx-auto max-w-5xl"><CustodeWeb.CurrentRunView.strip facts={@current_run} /></div>
      </div>
      <main
        id="conversation-scroll"
        phx-hook="ConversationScroll"
        data-prepend-generation={@prepend_generation}
        role="log"
        aria-live="polite"
        class="min-h-0 flex-1 overflow-y-auto px-4 py-6 sm:px-6"
      >
        <div class="mx-auto flex max-w-3xl flex-col gap-6">
          <section :if={@manager && @agent_id == nil} id="manager-setup" class="rounded-box border border-base-300 bg-base-100 p-6">
            <h2 class="font-semibold">Set up your caretaker</h2>
            <p class="mt-2 text-sm text-base-content/60">There is no custode to talk to yet. The existing setup form lets you review a caretaker before creating it.</p>
            <.link navigate="/console?new=caretaker" class="btn btn-primary btn-sm mt-4">Set up caretaker</.link>
          </section>
          <button
            :if={@has_older}
            id="load-older-conversation"
            type="button"
            class="btn btn-ghost btn-sm self-center"
            phx-click="older"
          >
            Load older history
          </button>

          <p
            :if={@timeline_items != [] and not @has_older}
            id="conversation-history-boundary"
            class="text-center text-xs text-base-content/40"
          >
            All currently available conversation history is loaded. Work updates cover
            retained turns; earlier provider transcripts may not be available.
          </p>

          <section
            :if={@agent_id && @timeline_items == []}
            id="conversation-empty"
            class="my-auto rounded-box border border-base-300 bg-base-100 p-8 text-center"
          >
            <h2 class="font-semibold">Start the conversation</h2>
            <p class="mt-2 text-sm text-base-content/60">
              Messages, exact agent outcomes, and recorded work updates appear here. Raw sensors and operational details
              remain in the control room.
            </p>
          </section>

          <section :if={@signal && @pending_exchange_id == nil && !manager_approval?(@manager_context, @signal)}
            id="conversation-pending-action" class="rounded-box border border-warning/40 bg-base-100 p-4">
            <p class="font-semibold">{@signal.headline}</p>
            <p class="mt-1 whitespace-pre-wrap break-words text-sm">{@signal.detail}</p>
            <.conversation_actions signal={@signal} message_gen={@message_gen} />
          </section>

          <div :for={unit <- @timeline_items} id={"timeline-#{unit.id}"} class="contents">
          <article
            :for={exchange <- if(unit.kind == :exchange, do: [unit.exchange], else: [])}
            id={"exchange-#{exchange.id}"}
            data-conversation-exchange
            data-status={exchange.status}
            class="flex flex-col gap-3"
          >
            <div :for={prompt <- exchange.prompts} class="contents">
              <div class="flex justify-end">
                <div class="max-w-[88%] rounded-box bg-primary px-4 py-3 text-primary-content shadow-sm sm:max-w-[75%]">
                  <p class="mb-1 text-xs font-semibold opacity-70">
                    {if prompt.continued, do: "you replied", else: "you"}
                  </p>
                  <.message_content text={prompt.text} agent={@agent_id} fold id={"prompt-#{prompt.id}"} />
                  <p class="mt-2 text-right font-mono text-[0.65rem] opacity-60">
                    <.ago at={prompt.inserted_at} />
                  </p>
                </div>
              </div>

              <div :if={prompt.detail} class="flex justify-start">
                <div class="max-w-[88%] rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-sm sm:max-w-[75%]">
                  <p class="mb-1 text-xs font-semibold text-base-content/50">{@agent_id}</p>
                  <.markdown text={prompt.detail} />
                </div>
              </div>
            </div>

            <div :if={final_answer(exchange)} class="flex justify-start">
              <div class="max-w-[88%] rounded-box border border-base-300 bg-base-100 px-4 py-3 shadow-sm sm:max-w-[75%]">
                <p class="mb-1 text-xs font-semibold text-base-content/50">{@agent_id}</p>
                <.message_content text={final_answer(exchange)} agent={@agent_id} markdown fold id={"answer-#{exchange.id}"} />
                <p class="mt-2 font-mono text-[0.65rem] text-base-content/40">
                  <.ago at={exchange.updated_at} />
                </p>
              </div>
            </div>

            <div
              :if={exchange.error}
              class="max-w-[88%] rounded-box border border-error/40 bg-error/5 px-4 py-3 text-sm sm:max-w-[75%]"
            >
              <p class="text-xs font-semibold text-error">{status_label(exchange.status)}</p>
              <p class="mt-1 whitespace-pre-wrap break-words text-base-content/70">{exchange.error}</p>
            </div>

            <div class="flex items-center gap-2 text-xs text-base-content/50">
              <.status_token tone={message_status_tone(exchange.status)} running={exchange.status == "executing"}>
                {status_label(exchange.status)}
              </.status_token>
              <span :if={exchange.provider} class="font-mono">{exchange.provider}</span>
            </div>

            <details :if={exchange.reports != [] && @show_updates}
              id={"exchange-reports-#{exchange.id}"} phx-hook="DisclosureState" class="text-sm">
              <summary class="link cursor-pointer text-xs">Interval reports ({length(exchange.reports)})</summary>
              <div :for={report <- exchange.reports} class="mt-2 rounded-box border border-base-300 p-3">
                <p class="text-xs text-base-content/50"><.ago at={report.at} /></p>
                <.interval_report report={report.entry["report"]} error={report.entry["report_error"]}
                  id={"linked-report-#{report.id}"} />
              </div>
            </details>

            <.conversation_actions
              :if={exchange.id == @pending_exchange_id && @signal && not manager_approval?(@manager_context, @signal)}
              signal={@signal}
              message_gen={@message_gen}
            />
          </article>
          <article :for={update <- if(unit.kind == :update && @show_updates, do: [unit.update], else: [])}
            id={"update-#{update.id}"} data-conversation-update class="flex justify-start">
            <div class="max-w-[88%] rounded-box border border-base-300 bg-base-100 px-4 py-3 sm:max-w-[75%]">
              <p class="mb-2 text-xs font-semibold text-base-content/60">{@agent_id} · Agent update</p>
              <.message_content text={update.entry["summary"] || "Recorded turn"} agent={@agent_id}
                markdown fold id={"update-summary-#{update.id}"} />
              <.interval_report report={update.entry["report"]} error={update.entry["report_error"]}
                id={"update-report-#{update.id}"} />
              <p class="mt-2 text-xs text-base-content/50"><.ago at={update.at} /> · {update_origin(update.entry)}</p>
            </div>
          </article>
          </div>
          <CustodeWeb.ProjectReportDigestPanel.panel :if={@manager} digest={@manager_context.project_digest} />
          <ManagerPanel.activity :if={@manager && @agent_id} context={@manager_context} include_said={false} />
        </div>
      </main>

      <footer :if={@subject && @subject.messageable} class="shrink-0 border-t border-base-300 bg-base-100 px-4 py-3 sm:px-6">
        <div class="mx-auto max-w-3xl">
          <ManagerPanel.prompts :if={@manager} sentences={@manager_context.also_try} />
          <.message_composer
            subject_id={@agent_id}
            state={@subject.state}
            routine={@subject.routine}
            message_gen={@message_gen}
            upload={@uploads.image}
          />
          <p :if={@notice} id="conversation-notice" class="mt-1 text-xs text-base-content/60">{@notice}</p>
        </div>
      </footer>
    </div>
    """
  end

  defp current_manager_plan(
         %{
           assigns: %{
             manager: true,
             agent_id: agent,
             manager_context: %{plan: %{action_id: action}}
           }
         },
         action
       )
       when is_binary(action) do
    with ^agent <- Actions.caretaker(),
         %{action_id: ^action} <- ManagerPanel.current_plan(agent) do
      {:ok, agent, action}
    else
      _stale -> {:error, :no_longer_pending}
    end
  end

  defp current_manager_plan(_socket, _action), do: {:error, :no_longer_pending}

  defp manager_approval?(%{plan: %{action_id: action}}, %Signal{resolving: resolving}),
    do:
      Enum.any?(
        resolving,
        &(&1.op in [:approve, :reject, :recover_gate] && &1.args[:action] == action)
      )

  defp manager_approval?(_context, _signal), do: false

  defp refresh_entry(%{assigns: %{manager: true}} = socket) do
    case Actions.caretaker() do
      id when id == socket.assigns.agent_id ->
        refresh_subject(socket)

      id ->
        socket
        |> assign(
          agent_id: id,
          exchanges: [],
          updates: [],
          timeline_items: [],
          before: nil,
          has_older: false
        )
        |> load_initial()
    end
  end

  defp refresh_entry(socket), do: refresh_subject(socket)

  defp load_initial(%{assigns: %{agent_id: nil}} = socket), do: refresh_subject(socket)

  defp load_initial(socket) do
    {:ok, page} = ConversationTimeline.page(socket.assigns.agent_id, limit: @page_size)

    socket
    |> assign(
      exchanges: page.exchanges,
      updates: page.updates,
      timeline_items: page.items,
      before: page.before,
      has_older: page.has_older
    )
    |> refresh_subject()
  end

  defp refresh_latest(%{assigns: %{agent_id: nil}} = socket), do: refresh_subject(socket)

  defp refresh_latest(socket) do
    {:ok, page} = ConversationTimeline.page(socket.assigns.agent_id, limit: @page_size)

    socket
    |> assign(
      exchanges:
        ConversationTimeline.refresh_exchanges(
          socket.assigns.agent_id,
          merge_exchanges(socket.assigns.exchanges, page.exchanges)
        ),
      updates: merge_updates(socket.assigns.updates, page.updates)
    )
    |> refresh_timeline()
    |> refresh_subject()
  end

  defp refresh_subject(%{assigns: %{agent_id: nil}} = socket) do
    socket
    |> assign(subject: nil, current_run: nil, signal: nil, pending_exchange_id: nil)
    |> refresh_context()
  end

  defp refresh_subject(socket) do
    routine = Routine.get(socket.assigns.agent_id)
    {:ok, status} = Agents.status(socket.assigns.agent_id)
    state = Custode.state_of(status)
    execution = ExecutionFacts.read(socket.assigns.agent_id, routine: routine)
    latest_provider = socket.assigns.exchanges |> List.last() |> then(&(&1 && &1.provider))

    contract = execution.active || execution.applied || execution.desired || %{}

    subject = %{
      id: socket.assigns.agent_id,
      routine: routine,
      status: status,
      state: state,
      provider: contract[:provider] || latest_provider,
      model: contract[:model],
      effort: contract[:effort],
      messageable: not is_nil(routine) or state != :offline
    }

    {signal, pending_exchange_id} = pending_signal(subject.id, socket.assigns.exchanges)

    assign(socket,
      subject: subject,
      current_run: current_run(subject.id),
      signal: signal,
      pending_exchange_id: pending_exchange_id
    )
    |> refresh_context()
  end

  defp current_run(id) do
    case Custode.CurrentRun.read(%{kind: :operator, id: "local-ui"}, id) do
      {:ok, facts} -> facts
      {:error, _reason} -> nil
    end
  end

  defp refresh_context(socket) do
    socket = AttentionSnapshot.refresh(socket)

    assign(socket,
      manager_context: if(socket.assigns.manager, do: ManagerPanel.read(socket.assigns.agent_id)),
      fleet_today: SpendLedger.fleet_today()
    )
  end

  defp pending_signal(agent_id, exchanges) do
    signal = Fleet.blocking_signal(agent_id)
    pending = if signal, do: Enum.find(Enum.reverse(exchanges), &pending_ops?(&1.status, signal))
    {signal, pending && pending.id}
  end

  defp refresh_timeline(socket) do
    assign(socket,
      timeline_items: ConversationTimeline.items(socket.assigns.exchanges, socket.assigns.updates)
    )
  end

  defp merge_updates(older, newer) do
    Map.new(older, &{&1.id, &1})
    |> Map.merge(Map.new(newer, &{&1.id, &1}))
    |> Map.values()
  end

  defp update_origin(%{"origin" => origin}) when is_binary(origin), do: "#{origin} turn"
  defp update_origin(%{"wake_reason" => reason}) when is_binary(reason), do: reason
  defp update_origin(_entry), do: "source not recorded"

  defp pending_ops?("waiting_for_input", %Signal{resolving: resolving}),
    do: Enum.any?(resolving, &(&1.op == :answer))

  defp pending_ops?("waiting_for_approval", %Signal{resolving: resolving}),
    do: Enum.any?(resolving, &(&1.op in [:approve, :reject, :recover_gate]))

  defp pending_ops?(_status, _signal), do: false

  defp merge_exchanges(older, newer) do
    older
    |> Map.new(&{&1.id, &1})
    |> Map.merge(Map.new(newer, &{&1.id, &1}))
    |> Map.values()
    |> Enum.sort_by(& &1.last_id)
  end

  defp save_images(%{assigns: %{subject: %{routine: %{} = routine}}} = socket) do
    consume_uploaded_entries(socket, :image, fn %{path: path}, entry ->
      {:ok, Attachments.store!(routine, path, entry.client_name)}
    end)
  end

  defp save_images(_socket), do: []

  defp sent_notice(:delivered), do: "sent"
  defp sent_notice(:queued), do: "queued for the next safe turn"
  defp sent_notice(:resumed), do: "resumed, then sent"
  defp sent_notice(:started), do: "started a turn with your message"

  defp action_notice(:dismiss_ask), do: "dismissed"
  defp action_notice(action), do: to_string(action)

  defp after_action(:ok, socket, notice) do
    {:noreply,
     socket
     |> assign(notice: notice, message_gen: socket.assigns.message_gen + 1)
     |> refresh_latest()}
  end

  defp after_action({:error, :empty}, socket, _notice), do: {:noreply, socket}

  defp after_action({:error, :no_longer_pending}, socket, _notice),
    do: {:noreply, socket |> assign(notice: "that is no longer pending") |> refresh_latest()}

  defp after_action({:error, reason}, socket, _notice),
    do: {:noreply, socket |> assign(notice: "failed: #{inspect(reason)}") |> refresh_latest()}

  defp final_answer(%{status: status, answer: answer, prompts: prompts})
       when status in ["completed", "failed", "refused"] and is_binary(answer) do
    details = Enum.map(prompts, & &1.detail)
    if answer in details, do: nil, else: answer
  end

  defp final_answer(_exchange), do: nil

  defp status_label("queued"), do: "queued"
  defp status_label("executing"), do: "working"
  defp status_label("waiting_for_input"), do: "waiting for your answer"
  defp status_label("waiting_for_approval"), do: "waiting for your approval"
  defp status_label("completed"), do: "complete"
  defp status_label("failed"), do: "failed"
  defp status_label("refused"), do: "refused"
  defp status_label(status), do: String.replace(status, "_", " ")

  defp message_status_tone("executing"), do: :info

  defp message_status_tone(status) when status in ["waiting_for_input", "waiting_for_approval"],
    do: :warning

  defp message_status_tone("completed"), do: :success
  defp message_status_tone(status) when status in ["failed", "refused"], do: :error
  defp message_status_tone(_status), do: :neutral

  defp execution_label(%{provider: nil}), do: "execution unknown"

  defp execution_label(subject) do
    [subject.provider, subject.model, effort_label(subject.effort)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp effort_label(nil), do: nil
  defp effort_label(effort), do: "#{effort} effort"
end
