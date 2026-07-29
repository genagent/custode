defmodule Custode.Operations.Missions.ProjectLegacyRoutine do
  @moduledoc false

  alias Custode.{LegacyMissionProjection, OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization

  @name "mission.project_legacy_routine"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          legacy_routine_id: [type: :string, required: true],
          strategy: [type: :string, required: true],
          mapping_identity: [type: :string, required: true],
          source: [type: :map, required: true],
          mission: [type: :map]
        },
        result_schema: %{mapping: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Project legacy routine into Mission scope"}
      )

    definition
  end

  def dispatch(observation, options) do
    observation = Map.new(observation)

    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: observation,
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      idempotency_key: "projection:#{LegacyMissionProjection.fingerprint(observation)}",
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id]
    })
  end

  defp handle(arguments, _envelope) do
    case LegacyMissionProjection.project(arguments) do
      {:ok, mapping, effects} ->
        {:ok, %{mapping: LegacyMissionProjection.render(mapping)}, effects}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call), do: LegacyMissionProjection.reconcile(call.arguments)

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "project_legacy_routine",
       legacy_routine_id: arguments.legacy_routine_id,
       mapping_identity: arguments.mapping_identity
     }}
  end

  defp scope(envelope), do: "legacy-routine:#{envelope.arguments.legacy_routine_id}"
  defp audit(arguments), do: "project legacy routine #{arguments.legacy_routine_id}"
end
