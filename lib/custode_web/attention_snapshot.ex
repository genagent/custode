defmodule CustodeWeb.AttentionSnapshot do
  @moduledoc "The shared header's current resolver snapshot, refreshed through existing PubSub."

  alias Custode.Attention.Fleet

  @events [
    :status_changed,
    :feed_entry,
    :repo_overview,
    :notebook_changed,
    :usage_changed,
    :operator_message_changed
  ]

  def refresh(socket), do: Phoenix.Component.assign(socket, :attention_signals, Fleet.signals())

  def relevant?({event, _payload}) when event in @events, do: true
  def relevant?(_message), do: false

  def refresh_for(socket, message) do
    if relevant?(message), do: refresh(socket), else: socket
  end
end
