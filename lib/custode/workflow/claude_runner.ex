defmodule Custode.Workflow.ClaudeRunner do
  @moduledoc "Trusted Forcola delegation with selected workflow observations; no physical settlement claim."
  @behaviour ClaudeWrapper.Runner
  alias Custode.Workflow.ExecutionObservation
  @runner ClaudeWrapper.Runner.Forcola

  @impl true
  def run(binary, args, opts, timeout) do
    if ExecutionObservation.scope(),
      do: run_selected(binary, args, opts, timeout),
      else: @runner.run(binary, args, opts, timeout)
  end

  defp run_selected(binary, args, opts, timeout) do
    case ExecutionObservation.request(binary, args, opts, timeout) do
      {:ok, token} -> delegate_selected(token, binary, args, opts, timeout)
      {:error, :runner_request_too_large} -> {:error, {:io, :workflow_observation_unavailable}}
      {:error, _reason} -> {:error, {:io, :workflow_observation_unbound}}
    end
  end

  defp delegate_selected(token, binary, args, opts, timeout) do
    outcome = @runner.run(binary, args, opts, timeout)

    case ExecutionObservation.returned(token, outcome) do
      :ok -> outcome
      {:error, _reason} -> {:error, {:io, :workflow_observation_unavailable}}
    end
  end

  @impl true
  def run_observed(binary, args, opts, timeout, observer) do
    if ExecutionObservation.scope(),
      do: {:error, {:io, :unsupported_selected_transport}},
      else: @runner.run_observed(binary, args, opts, timeout, observer)
  end

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    if ExecutionObservation.scope(),
      do: raise(ArgumentError, "selected workflow requires the one-shot transport"),
      else: @runner.stream_lines(binary, args, opts, timeout)
  end
end
