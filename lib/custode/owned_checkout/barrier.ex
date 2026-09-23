defmodule Custode.OwnedCheckout.Barrier do
  @moduledoc """
  Serializes provider lifecycle transitions with owned-checkout mutation.

  Provider agents update their registry status and emit transition telemetry
  before executing transition actions. Briefly taking the checkout lock in
  that synchronous handler means refresh either completes before a turn can
  enqueue work or observes the new busy status and refuses to start.
  """

  alias Custode.OwnedCheckout

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_codex, :agent, :transition]
  ]

  @doc false
  def attach do
    :telemetry.attach_many(
      "custode-owned-checkout-barrier",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @doc false
  def handle_event(_event, _measurements, %{agent_id: agent_id}, _config) do
    synchronize_agent(agent_id)
  rescue
    _exception -> :ok
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def synchronize_agent(agent_id, opts \\ []) do
    lookup = Keyword.get(opts, :routine, &Custode.Routine.get/1)

    with %{working_dir: working_dir} <- lookup.(agent_id),
         {:ok, destination} <- OwnedCheckout.path(agent_id, opts),
         true <- Path.expand(working_dir) == destination do
      OwnedCheckout.synchronize(destination, fn -> :ok end)
    else
      _not_managed -> :ok
    end
  end
end
