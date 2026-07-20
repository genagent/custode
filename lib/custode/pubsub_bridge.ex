defmodule Custode.PubSubBridge do
  @moduledoc """
  Telemetry -> Phoenix.PubSub, for the dashboard: every agent transition
  broadcasts `{:status_changed, agent_id}` on the `"agents"` topic. Feed
  entries ride the same topic as `{:feed_entry, entry}` (broadcast from
  `Custode.Feed`), so a LiveView subscribes once and gets both the "re-read
  status" nudge and the activity stream.
  """

  @topic "agents"

  def topic, do: @topic

  def attach do
    :telemetry.attach(
      "custode-pubsub-bridge",
      [:oban_claude, :agent, :transition],
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    broadcast({:status_changed, meta.agent_id})
  end

  @doc "Broadcast on the agents topic, quietly a no-op before PubSub is up."
  def broadcast(message) do
    if Process.whereis(Custode.PubSub) do
      Phoenix.PubSub.broadcast(Custode.PubSub, @topic, message)
    end

    :ok
  end

  @doc "Subscribe the calling process to the agents topic."
  def subscribe, do: Phoenix.PubSub.subscribe(Custode.PubSub, @topic)
end
