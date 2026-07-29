defmodule Custode.Operations.Missions.Create do
  @moduledoc false

  alias Custode.{Missions, OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization

  @name "mission.create"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          key: [type: :string, required: true],
          purpose: [type: :string, required: true],
          lifecycle: [type: :string, required: true],
          targets: [type: :list, required: true],
          policy_ref: [type: :string],
          budget_ref: [type: :string],
          context_ref: [type: :string],
          retention_seconds: [type: :integer],
          metadata: [type: :map]
        },
        result_schema: %{mission: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Create mission"}
      )

    definition
  end

  def dispatch(attrs, options) do
    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: Map.new(attrs),
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id]
    })
  end

  defp handle(arguments, _envelope) do
    case Missions.create(arguments) do
      {:ok, {:created, mission}} ->
        {:ok, %{mission: Missions.render(mission)},
         [%{type: "mission_created", mission_id: mission.mission_id}]}

      {:ok, {:existing, mission}} ->
        {:ok, %{mission: Missions.render(mission)}, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call) do
    case Missions.get_by_key(call.arguments["key"]) do
      nil ->
        :retry

      mission ->
        {:ok, %{mission: Missions.render(mission)},
         [%{type: "mission_created", mission_id: mission.mission_id}]}
    end
  end

  defp preview(arguments, _envelope),
    do: {:ok, %{effect: "create_mission", key: arguments.key}}

  defp scope(envelope), do: "mission:#{envelope.arguments.key}"
  defp audit(arguments), do: "create mission #{arguments.key}"
end
