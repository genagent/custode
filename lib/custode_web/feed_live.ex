defmodule CustodeWeb.FeedLive do
  @moduledoc "The global activity stream, full page. Filterable by agent (#21)."

  use Phoenix.LiveView

  alias CustodeWeb.AttentionSnapshot

  import CustodeWeb.Components

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Custode.PubSubBridge.subscribe()

    socket =
      socket
      |> AttentionSnapshot.refresh()
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())
      |> assign(agent_filter: nil, kind_filter: nil, agents: Custode.Feed.agents())
      |> stream_configure(:feed, dom_id: &feed_dom_id/1)

    {:ok, socket}
  end

  # The ?agent=<id> and ?kind=<category> query params drive the filters, so
  # they survive a reload and are shareable. Patching between filters re-runs
  # this without a remount, which keeps the PubSub subscription alive.
  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    filter = normalize_filter(params["agent"])
    kind = normalize_kind(params["kind"])

    feed =
      case filter do
        nil -> Custode.Feed.tail(feed_depth(kind))
        agent -> Custode.Feed.for_agent(agent, feed_depth(kind))
      end
      |> Enum.filter(&feed_category_match?(&1["event"], kind))
      |> Enum.reverse()

    socket =
      socket
      |> assign(agent_filter: filter, kind_filter: kind)
      |> stream(:feed, feed, reset: true)

    {:noreply, socket}
  end

  # A category filter is applied in-memory over the loaded window, so a
  # narrow category (attention is rare) pulls a deeper window to fill the
  # page; "all" keeps the cheap 100.
  defp feed_depth(nil), do: 100
  defp feed_depth(_category), do: 500

  @impl Phoenix.LiveView
  def handle_info({:feed_entry, entry}, socket) do
    socket =
      socket
      |> maybe_insert(entry)
      |> AttentionSnapshot.refresh()
      |> assign(fleet_today: Custode.SpendLedger.fleet_today())

    {:noreply, socket}
  end

  def handle_info(message, socket), do: {:noreply, AttentionSnapshot.refresh_for(socket, message)}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <.page attention_signals={@attention_signals} fleet_today={@fleet_today} active={:feed}>
      <div class="mx-auto mb-3 flex max-w-3xl flex-wrap items-center gap-2">
        <.link navigate="/messages" class="link mr-auto text-sm">Agent messages</.link>
        <span class="text-xs text-base-content/50">show:</span>
        <.link patch={feed_path(@agent_filter, nil)} class={["badge badge-sm", filter_class(@kind_filter == nil)]}>
          all
        </.link>
        <.link
          :for={category <- feed_categories()}
          patch={feed_path(@agent_filter, category)}
          class={["badge badge-sm", filter_class(@kind_filter == category)]}
        >
          {category}
        </.link>
      </div>
      <div :if={@agents != []} class="mx-auto mb-4 flex max-w-3xl flex-wrap items-center gap-2">
        <span class="text-xs text-base-content/50">agent:</span>
        <.link patch={feed_path(nil, @kind_filter)} class={["badge badge-sm", filter_class(@agent_filter == nil)]}>
          all
        </.link>
        <.link
          :for={agent <- @agents}
          patch={feed_path(agent, @kind_filter)}
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
    matches_agent? = socket.assigns.agent_filter in [nil, entry["agent"]]
    matches_kind? = feed_category_match?(entry["event"], socket.assigns.kind_filter)

    if matches_agent? and matches_kind? do
      stream_insert(socket, :feed, entry, at: 0)
    else
      socket
    end
  end

  # The /feed URL for a given (agent, kind) filter pair, so a chip preserves
  # the other axis instead of clearing it.
  defp feed_path(agent, kind) do
    query = [{"agent", agent}, {"kind", kind}] |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    if query == [], do: "/feed", else: "/feed?" <> URI.encode_query(query)
  end

  defp normalize_filter(nil), do: nil

  defp normalize_filter(agent) when is_binary(agent) do
    case String.trim(agent) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_kind(kind) when kind in ["attention", "turns", "sensors"], do: kind
  defp normalize_kind(_other), do: nil

  defp filter_class(true), do: "badge-primary"
  defp filter_class(false), do: "badge-ghost"

  defp feed_dom_id(entry) do
    "feed-" <> Integer.to_string(:erlang.phash2({entry["at"], entry["event"], entry["agent"]}))
  end
end
