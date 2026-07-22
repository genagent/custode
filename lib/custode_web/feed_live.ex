defmodule CustodeWeb.FeedLive do
  @moduledoc "The global activity stream, full page. Filterable by agent (#21)."

  use Phoenix.LiveView

  import CustodeWeb.Components

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    socket =
      socket
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())
      |> assign(agent_filter: nil, agents: Custode.Feed.agents())
      |> stream_configure(:feed, dom_id: &feed_dom_id/1)

    {:ok, socket}
  end

  # The ?agent=<id> query param drives the filter, so it survives a reload and
  # is shareable. Patching between filters re-runs this without a remount, which
  # keeps the PubSub subscription alive.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    filter = normalize_filter(params["agent"])

    feed =
      case filter do
        nil -> Custode.Feed.tail(100)
        agent -> Custode.Feed.for_agent(agent, 100)
      end
      |> Enum.reverse()

    socket =
      socket
      |> assign(agent_filter: filter)
      |> stream(:feed, feed, reset: true)

    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, entry}, socket) do
    socket =
      socket
      |> maybe_insert(entry)
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:feed}>
      <div :if={@agents != []} class="mx-auto mb-4 flex max-w-3xl flex-wrap items-center gap-2">
        <span class="text-xs text-base-content/50">filter:</span>
        <.link patch="/feed" class={["badge badge-sm", filter_class(@agent_filter == nil)]}>
          all
        </.link>
        <.link
          :for={agent <- @agents}
          patch={"/feed?agent=" <> agent}
          class={["badge badge-sm", filter_class(@agent_filter == agent)]}
        >
          {agent}
        </.link>
      </div>
      <ul
        id="feed"
        phx-update="stream"
        class="timeline timeline-vertical timeline-compact mx-auto max-w-3xl [--timeline-col-start:9rem]"
      >
        <.timeline_item :for={{dom_id, entry} <- @streams.feed} id={dom_id} entry={entry} />
      </ul>
    </.page>
    """
  end

  defp maybe_insert(socket, entry) do
    if socket.assigns.agent_filter in [nil, entry["agent"]] do
      stream_insert(socket, :feed, entry, at: 0)
    else
      socket
    end
  end

  defp normalize_filter(nil), do: nil

  defp normalize_filter(agent) when is_binary(agent) do
    case String.trim(agent) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp filter_class(true), do: "badge-primary"
  defp filter_class(false), do: "badge-ghost"

  defp feed_dom_id(entry) do
    "feed-" <> Integer.to_string(:erlang.phash2({entry["at"], entry["event"], entry["agent"]}))
  end
end
