defmodule Custode.Observer do
  @moduledoc """
  Telemetry -> Logger: one line per agent transition, per finished turn (with
  spend and the structured sweep report), and per failed claude call. This is
  the whole observability story for the demo; swap it for the phoenix_pubsub
  bridge when a UI shows up.
  """

  require Logger

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-observer", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    Logger.info("[#{meta.agent_id}] #{meta.from} -> #{meta.to}")
  end

  def handle_event([:oban_claude, :run, :stop], measurements, meta, _config) do
    out = ObanClaude.structured(meta.result) || %{}
    agent = agent_of(meta)
    cost = Float.round(measurements.cost_usd, 4)
    report = out["summary"] || String.slice(meta.result.result || "", 0, 120)

    Logger.info("[#{agent}] turn done ($#{cost}) directive=#{out["directive"]}: #{report}")
  end

  def handle_event([:oban_claude, :run, :exception], _measurements, meta, _config) do
    kind = if is_struct(meta.error), do: meta.error.kind, else: inspect(meta.error)
    Logger.warning("[#{agent_of(meta)}] turn failed: #{kind}")
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"
end
