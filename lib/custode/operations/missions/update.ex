defmodule Custode.Operations.Missions.Update do
  @moduledoc false

  alias Custode.{Missions, OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization

  @name "mission.update"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          mission_id: [type: :string, required: true],
          purpose: [type: :string],
          policy_ref: [type: :string],
          budget_ref: [type: :string],
          context_ref: [type: :string],
          retention_seconds: [type: :integer],
          metadata: [type: :map],
          target: [type: :map]
        },
        result_schema: %{mission: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator],
        authorization: &Authorization.operator/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: fn _call -> :retry end,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Update mission"}
      )

    definition
  end

  def dispatch(mission_id, attrs, options) do
    arguments = attrs |> Map.new() |> Map.put(:mission_id, mission_id)

    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: arguments,
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      mission_id: mission_id,
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id]
    })
  end

  defp handle(%{mission_id: mission_id} = arguments, _envelope) do
    case Missions.update(mission_id, Map.delete(arguments, :mission_id)) do
      {:ok, mission} ->
        {:ok, %{mission: Missions.render(mission)},
         [%{type: "mission_updated", mission_id: mission.mission_id}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp preview(arguments, _envelope),
    do: {:ok, %{effect: "update_mission", mission_id: arguments.mission_id}}

  defp scope(envelope), do: "mission:#{envelope.arguments.mission_id}"
  defp audit(arguments), do: "update mission #{arguments.mission_id}"
end
