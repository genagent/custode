defmodule Custode.Operations.Fleet.PauseAgent do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization

  @name "fleet.pause_agent"

  @spec name() :: String.t()
  def name, do: @name

  @spec definition() :: OperationDefinition.t()
  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{agent_id: [type: :string, required: true]},
        result_schema: %{
          agent_id: [type: :string, required: true],
          state: [type: :string, required: true]
        },
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator],
        authorization: &Authorization.operator/2,
        idempotency: %{required: true, scope: :agent},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{
          title: "Pause agent",
          description: "Emergency-pause an agent until an operator resumes it.",
          mcp: %{name: "pause_agent"}
        }
      )

    definition
  end

  @spec dispatch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def dispatch(agent_id, options) when is_binary(agent_id) and is_list(options) do
    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: %{agent_id: agent_id},
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp preview(%{agent_id: agent_id}, _envelope) do
    {:ok, %{effect: :pause_agent, agent_id: agent_id}}
  end

  defp handle(%{agent_id: agent_id}, _envelope) do
    case ObanClaude.Agent.emergency_pause(agent_id) do
      :ok ->
        {:ok, %{agent_id: agent_id, state: "paused"},
         [%{type: "agent_paused", agent_id: agent_id}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call) do
    agent_id = call.arguments["agent_id"]

    case ObanClaude.Agent.status(agent_id) do
      {:ok, :paused} ->
        {:ok, %{agent_id: agent_id, state: "paused"},
         [%{type: "agent_paused", agent_id: agent_id}]}

      _not_paused ->
        :retry
    end
  end

  defp audit(%{agent_id: agent_id}), do: "pause agent #{agent_id}"
end
