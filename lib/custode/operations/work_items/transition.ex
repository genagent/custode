defmodule Custode.Operations.WorkItems.Transition do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, WorkItems}
  alias Custode.Operations.Authorization

  @name "work.transition"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          work_item_id: [type: :string, required: true],
          expected_version: [type: :integer, required: true],
          state: [type: :string, required: true],
          phase: [type: :string, required: true],
          active_attempt_id: [type: :string],
          active_operation_call_id: [type: :string],
          waiting_condition: [type: :map],
          blocked_reason: [type: :map],
          outcome: [type: :map],
          evidence: [type: :map]
        },
        result_schema: %{
          work_item: [type: :map, required: true],
          event: [type: :map, required: true]
        },
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        precondition: &precondition/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Transition work item"}
      )

    definition
  end

  def dispatch(work_item_id, attrs, options) do
    arguments = attrs |> Map.new() |> Map.put(:work_item_id, work_item_id)
    work_item = WorkItems.get(work_item_id)
    expected_version = arguments[:expected_version] || arguments["expected_version"]

    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: arguments,
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      mission_id: work_item && work_item.mission.mission_id,
      work_item_id: work_item_id,
      expected_versions: %{work_item: expected_version},
      policy: options[:work_policy],
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp handle(arguments, envelope) do
    case WorkItems.transition(arguments.work_item_id, arguments, envelope) do
      {:ok, work_item, event} ->
        {:ok,
         %{
           work_item: WorkItems.render(work_item),
           event: WorkItems.render_event(event)
         }, [effect("work_item_transitioned", work_item, event)]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp precondition(arguments, _envelope),
    do: WorkItems.version_precondition(arguments.work_item_id, arguments.expected_version)

  defp reconcile(call) do
    case WorkItems.reconcile_call(call.call_id) do
      {:ok, work_item, event} ->
        {:ok,
         %{
           work_item: WorkItems.render(work_item),
           event: WorkItems.render_event(event)
         }, [effect("work_item_transitioned", work_item, event)]}

      :retry ->
        :retry
    end
  end

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "transition_work_item",
       work_item_id: arguments.work_item_id,
       expected_version: arguments.expected_version,
       state: arguments.state,
       phase: arguments.phase
     }}
  end

  defp effect(type, work_item, event) do
    %{
      type: type,
      work_item_id: work_item.work_item_id,
      event_id: event.event_id,
      version: work_item.version
    }
  end

  defp scope(envelope), do: "work-item:#{envelope.arguments.work_item_id}"
  defp audit(arguments), do: "transition work item #{arguments.work_item_id}"
end
