defmodule CustodeWeb.FeedLive do
  @moduledoc "The global activity stream, full page."

  use Phoenix.LiveView

  import CustodeWeb.Components

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    feed = Custode.Feed.tail(100) |> Enum.reverse()

    socket =
      socket
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())
      |> stream_configure(:feed, dom_id: &feed_dom_id/1)
      |> stream(:feed, feed)

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, entry}, socket) do
    socket =
      socket
      |> stream_insert(:feed, entry, at: 0)
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page fleet_today={@fleet_today} active={:feed}>
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

  defp feed_dom_id(entry) do
    "feed-" <> Integer.to_string(:erlang.phash2({entry["at"], entry["event"], entry["agent"]}))
  end
end
