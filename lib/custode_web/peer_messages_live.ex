defmodule CustodeWeb.PeerMessagesLive do
  @moduledoc "Read-only history of requests and replies between fleet agents."

  use Phoenix.LiveView

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  alias Custode.PeerMessages

  @operator %{kind: :operator}
  @page_size 50

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()
    socket = AttentionSnapshot.refresh(socket)
    {:ok, assign(socket, fleet_today: Custode.SpendLedger.fleet_today(), params: %{})}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    {:noreply, socket |> assign(:params, params) |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, %{"peer_message_id" => _id}}, socket),
    do: {:noreply, socket |> AttentionSnapshot.refresh() |> load()}

  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:feed}>
      <section class="mx-auto max-w-3xl">
        <div class="mb-4 flex flex-wrap items-center gap-3">
          <h1 class="text-xl font-semibold">Agent messages</h1>
          <.link navigate="/feed" class="link ml-auto text-sm">Fleet activity</.link>
          <.link :if={@thread_id || @participant} navigate="/messages" class="link text-sm">
            All agent messages
          </.link>
        </div>
        <p class="mb-4 text-sm text-base-content/60">
          Requests and evidence shared between agents. Delivered means the note reached the
          recipient's inbox. Acknowledged means the recipient marked it received, not that
          the work is complete. Viewing this page does not acknowledge messages.
        </p>
        <p :if={@participant} class="mb-3 text-sm">
          Sent or received by <.link navigate={"/console/#{@participant}"} class="link">{@participant}</.link>
        </p>
        <p :if={@thread_id} class="mb-3 text-sm text-base-content/60">Exchange, oldest first</p>
        <p :if={@error} role="alert" class="text-error">{@error}</p>
        <p :if={@messages == [] && !@error} id="peer-messages-empty" class="text-base-content/60">
          No agent messages in this view.
        </p>
        <div class="space-y-3">
          <article
            :for={message <- @messages}
            id={"peer-message-#{message.id}"}
            class="card border border-base-300 bg-base-100"
          >
            <div class="card-body gap-2 p-4">
              <div class="flex flex-wrap items-center gap-2 text-xs">
                <.link navigate={agent_path(message.sender)} class="link font-mono">{message.sender}</.link>
                <span aria-label="to">→</span>
                <.link navigate={agent_path(message.recipient)} class="link font-mono">{message.recipient}</.link>
                <span class="badge badge-ghost badge-sm">{message.kind}</span>
                <span class={["badge badge-outline badge-sm", message.delivery_state == "failed" && "badge-error"]}>
                  {delivery_label(message.delivery_state)}
                </span>
                <span :if={message.acknowledged_at} class="badge badge-outline badge-sm">Acknowledged</span>
                <span class="ml-auto text-base-content/50"><.ago at={message.inserted_at} /></span>
              </div>
              <h2 class="break-words font-semibold">{message.subject}</h2>
              <.foldable_text text={message.body} class="text-sm text-base-content/80" />
              <p :if={message.error} class="break-words text-sm text-error">{message.error}</p>
              <div class="flex flex-wrap gap-3 text-xs text-base-content/60">
                <.link :if={!@thread_id} navigate={"/messages/#{message.id}"} class="link">View exchange</.link>
                <span :if={message.delivered_at}>Delivered <.ago at={message.delivered_at} /></span>
                <span :if={message.acknowledged_at}>Acknowledged <.ago at={message.acknowledged_at} /></span>
              </div>
            </div>
          </article>
        </div>
        <nav aria-label="Message history pages" class="mt-4 flex gap-3 text-sm">
          <.link :if={@offset > 0} patch={page_path(@thread_id, @participant, max(@offset - @page_size, 0))} class="link">
            Newer messages
          </.link>
          <.link :if={length(@messages) == @page_size && @offset < 10_000} patch={page_path(@thread_id, @participant, @offset + @page_size)} class="link">
            Older messages
          </.link>
        </nav>
      </section>
    </.page>
    """
  end

  defp load(%{assigns: %{params: %{"id" => id}}} = socket) do
    offset = offset(socket.assigns.params["offset"])

    case PeerMessages.read(@operator, id) do
      {:ok, message} ->
        case PeerMessages.list(@operator,
               correlation_id: message.correlation_id,
               offset: offset,
               limit: 100
             ) do
          {:ok, messages} ->
            assign_view(socket, Enum.reverse(messages),
              thread_id: id,
              offset: offset,
              page_size: 100
            )

          {:error, _reason} ->
            assign_view(socket, [], error: "This exchange could not be loaded.")
        end

      {:error, _reason} ->
        assign_view(socket, [], error: "This exchange could not be found.")
    end
  end

  defp load(socket) do
    participant = socket.assigns.params["agent"]
    offset = offset(socket.assigns.params["offset"])

    case PeerMessages.list(@operator, participant: participant, offset: offset, limit: @page_size) do
      {:ok, messages} ->
        assign_view(socket, messages, participant: participant, offset: offset)

      {:error, _reason} ->
        assign_view(socket, [], error: "Messages could not be loaded for this filter.")
    end
  end

  defp assign_view(socket, messages, opts) do
    assign(socket,
      messages: messages,
      thread_id: opts[:thread_id],
      participant: opts[:participant],
      offset: opts[:offset] || 0,
      page_size: opts[:page_size] || @page_size,
      error: opts[:error]
    )
  end

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> min(number, 10_000)
      _other -> 0
    end
  end

  defp offset(_value), do: 0
  defp agent_path(agent), do: "/messages?" <> URI.encode_query(%{"agent" => agent})

  defp page_path(thread_id, _agent, offset) when is_binary(thread_id),
    do: "/messages/#{thread_id}?" <> URI.encode_query(%{"offset" => offset})

  defp page_path(nil, agent, offset) do
    query =
      [{"agent", agent}, {"offset", offset}] |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    "/messages?" <> URI.encode_query(query)
  end

  defp delivery_label("pending"), do: "Queued for delivery"
  defp delivery_label("delivered"), do: "Delivered"
  defp delivery_label("failed"), do: "Delivery failed"
end
