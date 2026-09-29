defmodule CustodeWeb.ConversationLive do
  @moduledoc """
  A focused, provider-neutral conversation with one agent.

  The transcript is the durable `Custode.OperatorMessage` projection. Provider
  transcripts and scheduled activity stay on their existing operational
  surfaces.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components,
    only: [ago: 1, app_header: 1, markdown: 1, message_content: 1, status_badge: 1]

  import CustodeWeb.Console.Composer, only: [message_composer: 1]
  import CustodeWeb.Console.Item, only: [conversation_actions: 1]

  alias Custode.Agents
  alias Custode.Attention.Fleet
  alias Custode.ExecutionFacts
  alias Custode.Operator.Actions
  alias Custode.Operator.Attachments
  alias Custode.OperatorMessages
  alias Custode.Routine
  alias Custode.Signal
  alias Custode.SpendLedger
  alias CustodeWeb.Console.Rail

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
       subject: nil,
       signal: nil,
       pending_exchange_id: nil,
       exchanges: [],
       before: nil,
       has_older: false,
       prepend_generation: 0,
       message_gen: 0,
       notice: nil
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(%{"id" => agent_id}, _uri, socket) do
    {:noreply,
     socket
     |> assign(agent_id: agent_id, notice: nil)
     |> load_initial()}
  end

  @impl Phoenix.LiveView
  def handle_info(
        {:operator_message_changed, agent_id},
        %{assigns: %{agent_id: agent_id}} = socket
      ),
      do: {:noreply, refresh_latest(socket)}

  def handle_info({:status_changed, agent_id}, %{assigns: %{agent_id: agent_id}} = socket),
    do: {:noreply, refresh_subject(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("older", _params, socket) do
    case OperatorMessages.conversation(socket.assigns.agent_id,
           limit: @page_size,
           before: socket.assigns.before
         ) do
      {:ok, page} ->
        {:noreply,
         socket
         |> assign(
           exchanges: merge_exchanges(page.exchanges, socket.assigns.exchanges),
           before: page.before,
           has_older: page.has_older,
           prepend_generation: socket.assigns.prepend_generation + 1
         )}

      {:error, _reason} ->
        {:noreply, assign(socket, notice: "older conversation history is unavailable")}
    end
  end

  def handle_event("validate_message", _params, socket), do: {:noreply, socket}

  def handle_event("drop_image", %{"ref" => ref}, socket),
    do: {:noreply, cancel_upload(socket, :image, ref)}

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

  def handle_event("reject", %{"agent" => agent, "action" => action} = params, socket) do
    :reject
    |> Actions.run(%{agent: agent, action: action}, params, @opts)
    |> after_action(socket, "rejected")
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
        active={:console}
        fleet_today={@fleet_today}
        attention_signals={@attention_signals}
      />
      <header class="shrink-0 border-b border-base-300 bg-base-100 px-4 py-3 sm:px-6">
        <div class="mx-auto flex max-w-5xl flex-wrap items-center gap-x-3 gap-y-1">
          <.link
            navigate={Rail.subject_path(@agent_id)}
            class="link text-xs font-semibold text-base-content/60"
          >
            &larr; control room
          </.link>
          <span class="text-base-content/30">/</span>
          <h1 class="font-mono text-lg font-bold">{@agent_id}</h1>
          <.status_badge :if={@subject} status={@subject.status} />
          <p :if={@subject} class="ml-auto font-mono text-xs text-base-content/50">
            {execution_label(@subject)}
          </p>
        </div>
      </header>

      <main
        id="conversation-scroll"
        phx-hook="ConversationScroll"
        data-prepend-generation={@prepend_generation}
        role="log"
        aria-live="polite"
        class="min-h-0 flex-1 overflow-y-auto px-4 py-6 sm:px-6"
      >
        <div class="mx-auto flex max-w-3xl flex-col gap-6">
          <button
            :if={@has_older}
            id="load-older-conversation"
            type="button"
            class="btn btn-ghost btn-sm self-center"
            phx-click="older"
          >
            load older messages
          </button>

          <p
            :if={@exchanges != [] and not @has_older}
            id="conversation-history-boundary"
            class="text-center text-xs text-base-content/40"
          >
            This is the beginning of the durable conversation history. Earlier provider
            transcripts may not be available.
          </p>

          <section
            :if={@exchanges == []}
            id="conversation-empty"
            class="my-auto rounded-box border border-base-300 bg-base-100 p-8 text-center"
          >
            <h2 class="font-semibold">Start the conversation</h2>
            <p class="mt-2 text-sm text-base-content/60">
              Messages and exact agent outcomes will appear here. Operational history,
              scheduled work and sensors remain in the control room.
            </p>
          </section>

          <article
            :for={exchange <- @exchanges}
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
                  <.message_content text={prompt.text} agent={@agent_id} />
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
                <.message_content text={final_answer(exchange)} agent={@agent_id} markdown />
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
              <span class={["badge badge-sm", message_status_class(exchange.status)]}>
                {status_label(exchange.status)}
              </span>
              <span :if={exchange.provider} class="font-mono">{exchange.provider}</span>
            </div>

            <.conversation_actions
              :if={exchange.id == @pending_exchange_id && @signal}
              signal={@signal}
              message_gen={@message_gen}
            />
          </article>
        </div>
      </main>

      <footer :if={@subject && @subject.messageable} class="shrink-0 border-t border-base-300 bg-base-100 px-4 py-3 sm:px-6">
        <div class="mx-auto max-w-3xl">
          <.message_composer
            subject_id={@agent_id}
            state={@subject.state}
            routine={@subject.routine}
            message_gen={@message_gen}
            upload={@uploads.image}
          />
          <p :if={@notice} class="mt-1 text-xs text-base-content/60">{@notice}</p>
        </div>
      </footer>
    </div>
    """
  end

  defp load_initial(socket) do
    {:ok, page} = OperatorMessages.conversation(socket.assigns.agent_id, limit: @page_size)

    socket
    |> assign(
      exchanges: page.exchanges,
      before: page.before,
      has_older: page.has_older
    )
    |> refresh_subject()
  end

  defp refresh_latest(socket) do
    {:ok, page} = OperatorMessages.conversation(socket.assigns.agent_id, limit: @page_size)

    socket
    |> assign(exchanges: merge_exchanges(socket.assigns.exchanges, page.exchanges))
    |> refresh_subject()
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
      signal: signal,
      pending_exchange_id: pending_exchange_id,
      attention_signals: Fleet.signals(),
      fleet_today: SpendLedger.fleet_today()
    )
  end

  defp pending_signal(_agent_id, []), do: {nil, nil}

  defp pending_signal(agent_id, exchanges) do
    with %Signal{} = signal <- Fleet.blocking_signal(agent_id),
         %{id: exchange_id} <-
           exchanges
           |> Enum.reverse()
           |> Enum.find(&pending_ops?(&1.status, signal)) do
      {signal, exchange_id}
    else
      _none -> {nil, nil}
    end
  end

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

  defp message_status_class("executing"), do: "badge-info"

  defp message_status_class(status) when status in ["waiting_for_input", "waiting_for_approval"],
    do: "badge-warning"

  defp message_status_class("completed"), do: "badge-success badge-outline"
  defp message_status_class(status) when status in ["failed", "refused"], do: "badge-error"
  defp message_status_class(_status), do: "badge-outline"

  defp execution_label(%{provider: nil}), do: "execution unknown"

  defp execution_label(subject) do
    [subject.provider, subject.model, effort_label(subject.effort)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp effort_label(nil), do: nil
  defp effort_label(effort), do: "#{effort} effort"
end
