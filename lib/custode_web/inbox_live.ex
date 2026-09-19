defmodule CustodeWeb.InboxLive do
  @moduledoc """
  The inbox (#301): only what agents raised to a human, with unread state and
  a hard bottom.

  A rendering of `Custode.Operator.Inbox`, which is itself a projection of
  `Custode.Attention`. This module contains no ranking and no idea of what
  counts as needing a human; both live in the resolver, which is the point.

  Rows render their buttons from each item's `actions`, so a new signal kind
  shows up here working, with no change to this file.
  """

  use Phoenix.LiveView

  import CustodeWeb.Components

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
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("approve", %{"agent" => id, "action" => action_id}, socket) do
    Custode.approve_action(id, action_id, via: :liveview)
    {:noreply, refresh(socket)}
  end

  def handle_event("reject", %{"agent" => id, "action" => action_id}, socket) do
    Custode.reject_with_note(id, action_id, "rejected from the inbox", via: :liveview)
    {:noreply, refresh(socket)}
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
    items = Inbox.items()
    unread = if socket.assigns.since, do: length(Inbox.since(socket.assigns.since)), else: 0

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
    <.page fleet_today={@fleet_today} active={:inbox} unread={@unread}>
      <div class="mb-4 flex flex-wrap items-baseline gap-3">
        <h1 class="text-xl font-bold">Inbox</h1>
        <span :if={@unread > 0} class="badge badge-warning font-mono">{@unread} new</span>
        <span class="text-xs text-base-content/40">{since_label(@since)}</span>
      </div>

      <div :if={@items == []} class="rounded-xl border border-base-300/60 p-8 text-center">
        <p class="font-medium">Nothing needs you.</p>
        <p class="mt-1 text-sm text-base-content/50">
          The fleet is working or resting. Its state is on the
          <.link navigate="/" class="link">fleet page</.link>.
        </p>
      </div>

      <ul class="flex flex-col divide-y divide-base-300/60">
        <li :for={item <- @items} class={["py-4", unread_tone(item, @since)]}>
          <div class="flex flex-wrap items-baseline gap-2">
            <.link
              :if={item.kind != :suggestion}
              navigate={"/agents/#{item.subject}"}
              class="font-mono font-bold hover:underline"
            >
              {item.subject}
            </.link>
            <span :if={item.kind == :suggestion} class="font-mono font-bold">{item.subject}</span>
            <span class={["badge badge-sm", kind_class(item.kind)]}>{kind_label(item.kind)}</span>
            <span class="ml-auto font-mono text-xs text-base-content/40">
              <.ago :if={item.at} at={item.at} />
            </span>
          </div>

          <p class="mt-1 font-medium">{item.headline}</p>
          <p :if={item.detail} class="mt-1 line-clamp-3 text-sm text-base-content/70">
            {item.detail}
          </p>

          <%!-- The reply box is the affordance a QUESTION deserves: the agent
                made a judgment call and wants a human read, which is a
                conversation and not a button reading approve. --%>
          <form
            :if={replying?(@replying_to, item)}
            class="mt-2 flex flex-col gap-2"
            phx-submit="reply_send"
          >
            <input type="hidden" name="ask" value={ask_id(item)} />
            <textarea
              name="text"
              rows="3"
              autofocus
              class="textarea textarea-bordered w-full text-sm"
              placeholder={"reply to #{item.subject}..."}
            ></textarea>
            <div class="flex gap-2">
              <button type="submit" class="btn btn-primary btn-xs">send</button>
              <button type="button" class="btn btn-ghost btn-xs" phx-click="reply_cancel">
                cancel
              </button>
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
    <button
      class="btn btn-primary btn-xs"
      phx-click="reply_open"
      phx-value-ask={@action.args[:ask]}
    >
      {@action.label}
    </button>
    """
  end

  defp action(%{action: %{op: :approve}} = assigns) do
    ~H"""
    <button
      class="btn btn-success btn-xs"
      phx-click="approve"
      phx-value-agent={@action.args[:agent]}
      phx-value-action={@action.args[:action]}
    >
      {@action.label}
    </button>
    """
  end

  defp action(%{action: %{op: :reject}} = assigns) do
    ~H"""
    <button
      class="btn btn-ghost btn-xs"
      phx-click="reject"
      phx-value-agent={@action.args[:agent]}
      phx-value-action={@action.args[:action]}
    >
      {@action.label}
    </button>
    """
  end

  defp action(%{action: %{op: op}} = assigns)
       when op in [:apply_suggestion, :dismiss_suggestion] do
    ~H"""
    <button
      class={["btn btn-xs", (@action.op == :apply_suggestion && "btn-primary") || "btn-ghost"]}
      phx-click={to_string(@action.op)}
      phx-value-agent={@action.args[:agent]}
      phx-value-field={@action.args[:field]}
      phx-value-proposed={@action.args[:proposed]}
    >
      {@action.label}
    </button>
    """
  end

  # Anything else is navigation: the op has no inbox handler, so send the
  # operator where it can be dealt with rather than pretending to act.
  defp action(assigns) do
    ~H"""
    <.link navigate={"/agents/#{@subject}"} class="btn btn-outline btn-xs">
      {@action.label}
    </.link>
    """
  end

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
  defp kind_label(:red_main), do: "red branch"
  defp kind_label(:disowned_check), do: "not its work"
  defp kind_label(:needs_answer), do: "question"
  defp kind_label(:approval), do: "approval"
  defp kind_label(:rail_hit), do: "rail"
  defp kind_label(:suggestion), do: "suggestion"
  defp kind_label(kind), do: to_string(kind)

  defp kind_class(:host_down), do: "badge-error"
  defp kind_class(:red_main), do: "badge-error"
  defp kind_class(:disowned_check), do: "badge-warning"
  defp kind_class(:needs_answer), do: "badge-accent"
  defp kind_class(:approval), do: "badge-warning"
  defp kind_class(:rail_hit), do: "badge-error"
  defp kind_class(_kind), do: "badge-ghost"
end
