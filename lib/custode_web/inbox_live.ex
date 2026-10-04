defmodule CustodeWeb.InboxLive do
  @moduledoc """
  The inbox (#301): only what agents raised to a human, with unread state and
  a hard bottom.

  A rendering of `Custode.Operator.Inbox`, which is itself a projection of
  `Custode.Attention`. This module contains no ranking and no idea of what
  counts as needing a human; both live in the resolver, which is the point.

  Rows render their buttons from each item's `actions`, so a new signal kind
  shows up here working, with no change to this file. A new OP is the
  exception: one the inbox can perform needs a renderer and a handler here,
  which is what the workflow ops got in #447.
  """

  use Phoenix.LiveView

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  alias Custode.Operator.Actions
  alias Custode.Operator.Inbox

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    # The read mark is taken ONCE, on arrival, and the page keeps showing what
    # was new when the operator got here. Re-reading it on every refresh would
    # make items silently stop being new while being looked at.
    since = Inbox.last_read_at()
    if connected?(socket), do: Inbox.mark_read()

    {:ok, socket |> assign(since: since, replying_to: nil) |> refresh()}
  end

  @impl Phoenix.LiveView
  def handle_info({:status_changed, _agent_id}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:feed_entry, _entry}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:repo_overview, _repo}, socket), do: {:noreply, refresh(socket)}

  def handle_info(message, socket) do
    {:noreply, if(AttentionSnapshot.relevant?(message), do: refresh(socket), else: socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("approve", %{"agent" => id, "action" => action_id}, socket) do
    Custode.approve_action(id, action_id, via: :liveview)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"agent" => id, "action" => action_id} = params, socket) do
    Custode.reject_with_note(id, action_id, params["reason"],
      via: :liveview,
      standing: params["one_off"] != "true"
    )

    {:noreply, refresh(socket)}
  end

  def handle_event("recover_gate", %{"agent" => id, "action" => action_id}, socket) do
    case Actions.recover_gate(id, action_id, via: :liveview) do
      :ok ->
        {:noreply,
         socket |> put_flash(:info, "approval requeued for agent re-evaluation") |> refresh()}

      {:error, reason} ->
        {:noreply,
         socket |> put_flash(:error, "approval recovery failed: #{inspect(reason)}") |> refresh()}
    end
  end

  # The workflow decisions (#447), through `Custode.Operator.Actions` like
  # every handler should be (design/010 decision 4): the workflows page makes
  # the same three calls, so the two pages cannot come to differ.
  def handle_event("approve_launch", %{"id" => id}, socket) do
    case Actions.approve_launch(id, via: :liveview) do
      {:ok, run} ->
        {:noreply,
         socket
         |> put_flash(:info, "launched #{run.workflow} -- run #{run.run_id}")
         |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "launch refused: #{inspect(reason)}") |> refresh()}
    end
  end

  def handle_event("reject_launch", %{"id" => id}, socket) do
    Actions.reject_launch(id, "rejected from the inbox", via: :liveview)
    {:noreply, socket |> put_flash(:info, "launch rejected") |> refresh()}
  end

  def handle_event("resume_run", %{"id" => id}, socket) do
    case Actions.resume_run(id, via: :liveview) do
      {:ok, _run} ->
        {:noreply, socket |> put_flash(:info, "run #{id} resumed on a raised rail") |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, "resume refused: #{inspect(reason)}") |> refresh()}
    end
  end

  # A question is a conversation, so the affordance is a reply box rather than
  # a button. Opening one is view state and stays in the socket.
  def handle_event("reply_open", %{"ask" => ask_id}, socket) do
    {:noreply, assign(socket, replying_to: to_integer(ask_id))}
  end

  def handle_event("reply_cancel", _params, socket) do
    {:noreply, assign(socket, replying_to: nil)}
  end

  def handle_event("reply_send", %{"ask" => ask_id, "text" => text}, socket) do
    case Custode.Asks.answer(to_integer(ask_id), text) do
      {:ok, ask} ->
        {:noreply,
         socket
         |> assign(replying_to: nil)
         |> put_flash(:info, "answered; #{ask.agent_id} reads it on its next sweep")
         |> refresh()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, to_string(reason))}
    end
  end

  def handle_event("dismiss_ask", %{"ask" => ask_id}, socket) do
    ask_id = to_integer(ask_id)

    socket =
      if socket.assigns.replying_to == ask_id,
        do: assign(socket, replying_to: nil),
        else: socket

    case Actions.dismiss_ask(ask_id) do
      :ok ->
        {:noreply, socket |> put_flash(:info, "ask dismissed; no answer sent") |> refresh()}

      {:error, reason} ->
        {:noreply, socket |> put_flash(:error, to_string(reason)) |> refresh()}
    end
  end

  def handle_event("apply_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params

    case Custode.Suggestions.apply(id, field, proposed) do
      {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> refresh()}
      {:error, reason} -> {:noreply, put_flash(socket, :error, "refused: #{inspect(reason)}")}
    end
  end

  def handle_event("dismiss_suggestion", params, socket) do
    %{"agent" => id, "field" => field, "proposed" => proposed} = params
    {:ok, message} = Custode.Suggestions.dismiss(id, field, proposed)
    {:noreply, socket |> put_flash(:info, message) |> refresh()}
  end

  defp refresh(socket) do
    socket = AttentionSnapshot.refresh(socket)
    items = Inbox.items(socket.assigns.attention_signals)

    unread =
      if socket.assigns.since, do: length(Inbox.unread(items, socket.assigns.since)), else: 0

    assign(socket,
      items: items,
      unread: unread,
      fleet_today: Custode.SpendLedger.fleet_today()
    )
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:inbox} unread={@unread}>
      <.page_header
        title="Inbox"
        summary={"#{length(@items)} #{if length(@items) == 1, do: "item", else: "items"} · #{@unread} new · #{since_label(@since)}"}
      />

      <div :if={@items == []} class="rounded-xl border border-base-300/60 p-8 text-center">
        <p class="font-medium">Nothing needs you.</p>
        <p class="mt-1 text-sm text-base-content/50">
          The fleet is working or resting. Its state is on the
          <.link navigate="/" class="link">console</.link>.
        </p>
      </div>

      <ul :if={@items != []} aria-label="Inbox items" class="divide-y divide-base-300 rounded-box border border-base-300 bg-base-100">
        <li :for={item <- @items} class={["p-4", unread_tone(item, @since)]}>
          <div class="flex flex-wrap items-baseline gap-2">
            <.link
              :if={subject_path(item)}
              navigate={subject_path(item)}
              class="font-mono font-bold hover:underline"
            >
              {item.subject}
            </.link>
            <span :if={!subject_path(item)} class="font-mono font-bold">{item.subject}</span>
            <.status_token tone={kind_tone(item.kind)}>{kind_label(item.kind)}</.status_token>
            <span class="ml-auto font-mono text-xs text-base-content/40">
              <.ago :if={item.at} at={item.at} />
            </span>
          </div>

          <p class="mt-1 font-medium">{item.headline}</p>
          <.foldable_text
            :if={item.detail}
            text={item.detail}
            class="mt-1 text-sm text-base-content/70"
          />

          <%!-- The reply box is the affordance a QUESTION deserves: the agent
                made a judgment call and wants a human read, which is a
                conversation and not a button reading approve. --%>
          <form
            :if={replying?(@replying_to, item)}
            class="mt-2 flex flex-col gap-2"
            phx-submit="reply_send"
          >
            <input type="hidden" name="ask" value={ask_id(item)} />
            <label for={"inbox-reply-#{ask_id(item)}"} class="text-sm font-medium">Reply to {item.subject}</label>
            <textarea
              id={"inbox-reply-#{ask_id(item)}"}
              name="text"
              rows="3"
              autofocus
              class="textarea textarea-bordered w-full text-sm"
              aria-describedby={"inbox-reply-help-#{ask_id(item)}"}
            ></textarea>
            <p id={"inbox-reply-help-#{ask_id(item)}"} class="text-xs text-base-content/60">Sends your answer to this agent's question.</p>
            <div class="flex gap-2">
              <.action_button type="submit" variant={:primary}>Send</.action_button>
              <.action_button type="button" variant={:quiet} phx-click="reply_cancel">
                Cancel
              </.action_button>
              <.action
                :for={action <- item.actions}
                :if={action.op == :dismiss_ask}
                action={action}
                subject={item.subject}
              />
            </div>
          </form>

          <div :if={!replying?(@replying_to, item)} class="mt-2 flex flex-wrap gap-2">
            <.action :for={action <- item.actions} action={action} subject={item.subject} />
          </div>
        </li>
      </ul>

      <%!-- The hard bottom. "That is everything" is the sentence that makes an
            inbox trustworthy, and it is only trustworthy if the omissions are
            named rather than silently dropped. --%>
      <div :if={@items != []} class="mt-6 rounded-lg bg-base-200/50 px-4 py-3 text-sm">
        <span class="font-medium">That's everything.</span>
        <span class="text-base-content/50">
          Sweeps, sensor pings and journal entries happened too. They're on their agents, not here.
        </span>
      </div>
    </.page>
    """
  end

  attr(:action, :map, required: true)
  attr(:subject, :string, required: true)

  # One renderer for every action, driven by the op name the signal carried.
  # A new signal kind arrives with working buttons and no edit here.
  defp action(%{action: %{op: :answer_ask}} = assigns) do
    ~H"""
    <.action_button
      variant={:primary}
      phx-click="reply_open"
      phx-value-ask={@action.args[:ask]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :dismiss_ask}} = assigns) do
    ~H"""
    <.action_button
      type="button"
      variant={:quiet}
      phx-click="dismiss_ask"
      phx-value-ask={@action.args[:ask]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :approve}} = assigns) do
    ~H"""
    <.action_button
      variant={:primary}
      phx-click="approve"
      phx-value-agent={@action.args[:agent]}
      phx-value-action={@action.args[:action]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :reject}} = assigns) do
    ~H"""
    <.reject_form agent={@action.args[:agent]} action={@action.args[:action]} />
    """
  end

  defp action(%{action: %{op: :recover_gate}} = assigns) do
    ~H"""
    <.action_button
      variant={:primary}
      phx-click="recover_gate"
      phx-value-agent={@action.args[:agent]}
      phx-value-action={@action.args[:action]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: op}} = assigns)
       when op in [:apply_suggestion, :dismiss_suggestion] do
    ~H"""
    <.action_button
      variant={if @action.op == :apply_suggestion, do: :primary, else: :quiet}
      phx-click={to_string(@action.op)}
      phx-value-agent={@action.args[:agent]}
      phx-value-field={@action.args[:field]}
      phx-value-proposed={@action.args[:proposed]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :approve_launch}} = assigns) do
    ~H"""
    <.action_button
      variant={:primary}
      phx-click="approve_launch"
      phx-value-id={@action.args[:proposal]}
      data-confirm={"Launch #{@subject}?"}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :reject_launch}} = assigns) do
    ~H"""
    <.action_button
      variant={:quiet}
      phx-click="reject_launch"
      phx-value-id={@action.args[:proposal]}
    >
      {@action.label}
    </.action_button>
    """
  end

  defp action(%{action: %{op: :resume_run}} = assigns) do
    ~H"""
    <.action_button
      variant={:primary}
      phx-click="resume_run"
      phx-value-id={@action.args[:run]}
      data-confirm="Double this run's rail and let it go on?"
    >
      {@action.label}
    </.action_button>
    """
  end

  # A workflow signal has no agent page to fall through to (#447).
  defp action(%{action: %{op: :open_workflows}} = assigns) do
    ~H"""
    <.link navigate="/workflows" class={action_classes(:secondary)}>{@action.label}</.link>
    """
  end

  # Anything else is navigation: the op has no inbox handler, so send the
  # operator where it can be dealt with rather than pretending to act.
  defp action(assigns) do
    ~H"""
    <.link navigate={"/console/#{@subject}"} class={action_classes(:secondary)}>
      {@action.label}
    </.link>
    """
  end

  # Where a row's subject leads. An agent's signal leads to the agent; a
  # workflow's leads to the workflows page, since its subject names a run and
  # not an agent (#447); a suggestion has no page of its own.
  defp subject_path(%{kind: :suggestion}), do: nil

  defp subject_path(%{kind: kind}) when kind in [:workflow_launch, :workflow_rail],
    do: "/workflows"

  defp subject_path(%{subject: subject}),
    do: "/console/" <> URI.encode(subject, &URI.char_unreserved?/1)

  defp replying?(replying_to, item), do: replying_to != nil and replying_to == ask_id(item)

  defp ask_id(%{kind: :needs_answer, actions: actions}) do
    Enum.find_value(actions, fn
      %{op: :answer_ask, args: %{ask: id}} -> id
      _other -> nil
    end)
  end

  defp ask_id(_item), do: nil

  defp unread_tone(_item, nil), do: nil

  defp unread_tone(%{at: nil}, _since), do: nil

  defp unread_tone(%{at: at}, since) do
    if DateTime.compare(at, since) == :gt, do: "border-l-2 border-warning pl-3", else: nil
  end

  defp since_label(nil), do: "first look"

  defp since_label(%DateTime{} = at) do
    "since you last looked, " <> ago_text(at)
  end

  defp kind_label(:host_down), do: "host down"
  defp kind_label(:ci_infrastructure), do: "GitHub Actions"
  defp kind_label(:red_main), do: "red branch"
  defp kind_label(:turn_failing), do: "turns failing"
  defp kind_label(:disowned_check), do: "not its work"
  defp kind_label(:needs_answer), do: "question"
  defp kind_label(:approval), do: "approval"
  defp kind_label(:workflow_launch), do: "launch gate"
  defp kind_label(:workflow_rail), do: "run rail"
  defp kind_label(:rail_hit), do: "rail"
  defp kind_label(:suggestion), do: "suggestion"
  defp kind_label(kind), do: to_string(kind)

  defp kind_tone(:host_down), do: :error
  defp kind_tone(:red_main), do: :error
  defp kind_tone(:ci_infrastructure), do: :warning
  defp kind_tone(:turn_failing), do: :error
  defp kind_tone(:disowned_check), do: :warning
  defp kind_tone(:needs_answer), do: :warning
  defp kind_tone(:approval), do: :warning
  defp kind_tone(:workflow_launch), do: :warning
  defp kind_tone(:workflow_rail), do: :warning
  defp kind_tone(:rail_hit), do: :error
  defp kind_tone(_kind), do: :neutral
end
