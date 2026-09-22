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

  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      Logger.error(
        "Custode.Observer handler error (kept attached): " <> Exception.message(exception)
      )

      :ok
  end

  defp do_handle_event([provider, :agent, :transition], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    Logger.info("[#{meta.agent_id}] #{meta.from} -> #{meta.to}")
  end

  defp do_handle_event(
         [provider, :run, :stop],
         _measurements,
         %{job: %{meta: %{"custode_kind" => "gate_review"}}} = meta,
         _config
       )
       when provider in [:oban_claude, :oban_codex] do
    Logger.info("[#{agent_of(meta)}] cross-provider gate review finished")
  end

  defp do_handle_event([provider, :run, :stop], measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    out = structured(provider, meta.result) || %{}
    agent = agent_of(meta)
    cost = round_cost(measurements.cost_usd)
    report = out["summary"] || String.slice(text(provider, meta.result) || "", 0, 120)

    case failure_kind(meta.result) do
      nil ->
        Logger.info("[#{agent}] turn done ($#{cost}) directive=#{out["directive"]}: #{report}")

      kind ->
        Logger.warning("[#{agent}] turn failed: #{kind}")
    end
  end

  defp do_handle_event(
         [provider, :run, :exception],
         _measurements,
         %{job: %{meta: %{"custode_kind" => "gate_review"}}} = meta,
         _config
       )
       when provider in [:oban_claude, :oban_codex] do
    Logger.warning("[#{agent_of(meta)}] cross-provider gate review failed")
  end

  defp do_handle_event([provider, :run, :exception], _measurements, meta, _config)
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
  defp failure_kind(%ClaudeWrapper.Result{is_error: true}), do: :result_error
  defp failure_kind(%CodexWrapper.Result{success: false}), do: :command_failed
  defp failure_kind(_result), do: nil

  defp round_cost(cost) when is_number(cost), do: Float.round(cost * 1.0, 4)
  defp round_cost(_other), do: 0.0
end
