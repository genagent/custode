defmodule Custode.Observer do
  @moduledoc """
  Telemetry -> Logger: one line per agent transition, per finished turn (with
  spend and the structured sweep report), and per failed provider call. This is
  the whole observability story for the demo; swap it for the phoenix_pubsub
  bridge when a UI shows up.
  """

  require Logger

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception],
    [:oban_codex, :agent, :transition],
    [:oban_codex, :run, :stop],
    [:oban_codex, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-observer", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event([provider, :agent, :transition], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    Logger.info("[#{meta.agent_id}] #{meta.from} -> #{meta.to}")
  end

  def handle_event(
        [provider, :run, :stop],
        _measurements,
        %{job: %{meta: %{"custode_kind" => "gate_review"}}} = meta,
        _config
      )
      when provider in [:oban_claude, :oban_codex] do
    Logger.info("[#{agent_of(meta)}] cross-provider gate review finished")
  end

  def handle_event([provider, :run, :stop], measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    out = structured(provider, meta.result) || %{}
    agent = agent_of(meta)
    cost = Float.round(measurements.cost_usd, 4)
    report = out["summary"] || String.slice(text(provider, meta.result) || "", 0, 120)

    if failed_result?(meta.result),
      do: Logger.warning("[#{agent}] turn failed: command_failed"),
      else:
        Logger.info("[#{agent}] turn done ($#{cost}) directive=#{out["directive"]}: #{report}")
  end

  def handle_event(
        [provider, :run, :exception],
        _measurements,
        %{job: %{meta: %{"custode_kind" => "gate_review"}}} = meta,
        _config
      )
      when provider in [:oban_claude, :oban_codex] do
    Logger.warning("[#{agent_of(meta)}] cross-provider gate review failed")
  end

  def handle_event([provider, :run, :exception], _measurements, meta, _config)
      when provider in [:oban_claude, :oban_codex] do
    kind = if is_struct(meta.error), do: meta.error.kind, else: inspect(meta.error)
    Logger.warning("[#{agent_of(meta)}] turn failed: #{kind}")
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"

  defp structured(:oban_claude, result), do: ObanClaude.structured(result)
  defp structured(:oban_codex, result), do: ObanCodex.structured(result)
  defp text(:oban_claude, result), do: result.result
  defp text(:oban_codex, result), do: ObanCodex.text(result)
  defp failed_result?(%CodexWrapper.Result{success: false}), do: true
  defp failed_result?(_result), do: false
end
