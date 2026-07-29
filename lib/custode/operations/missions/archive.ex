defmodule Custode.Operations.Missions.Archive do
  @moduledoc false

  alias Custode.{Missions, OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization

  @name "mission.archive"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{mission_id: [type: :string, required: true]},
        result_schema: %{mission: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator],
        authorization: &Authorization.operator/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Archive mission"}
      )

    definition
  end

  def dispatch(mission_id, options) do
    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: %{mission_id: mission_id},
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      mission_id: mission_id,
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id]
    })
  end

  defp handle(%{mission_id: mission_id}, envelope) do
    case Missions.archive(mission_id, envelope.call_id) do
      {:ok, mission} ->
        {:ok, %{mission: Missions.render(mission)},
         [%{type: "mission_archived", mission_id: mission.mission_id}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call) do
    case Missions.get(call.arguments["mission_id"]) do
      %{status: "archived"} = mission ->
        {:ok, %{mission: Missions.render(mission)},
         [%{type: "mission_archived", mission_id: mission.mission_id}]}

      _other ->
        :retry
    end
  end

  defp preview(arguments, _envelope),
    do: {:ok, %{effect: "archive_mission", mission_id: arguments.mission_id}}

  defp scope(envelope), do: "mission:#{envelope.arguments.mission_id}"
  defp audit(arguments), do: "archive mission #{arguments.mission_id}"
end
