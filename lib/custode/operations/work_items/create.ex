defmodule Custode.Operations.WorkItems.Create do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, WorkItems}
  alias Custode.Operations.Authorization

  @name "work.create"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          mission_id: [type: :string, required: true],
          parent_work_item_id: [type: :string],
          kind: [type: :string, required: true],
          workflow_version: [type: :integer, required: true],
          objective: [type: :string, required: true],
          acceptance_criteria: [type: :map, required: true],
          phase: [type: :string, required: true],
          priority: [type: :integer],
          policy_ref: [type: :string],
          source: [type: :string, required: true],
          external_key: [type: :string, required: true],
          evidence: [type: :map]
        },
        result_schema: %{work_item: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Create work item"}
      )

    definition
  end

  def dispatch(attrs, options) do
    attrs = Map.new(attrs)

    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: attrs,
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      mission_id: attrs[:mission_id] || attrs["mission_id"],
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp handle(arguments, envelope) do
    case WorkItems.create(arguments, envelope) do
      {:ok, status, work_item, event} ->
        effects =
          if status == :created do
            [effect("work_item_created", work_item, event)]
          else
            []
          end

        {:ok, %{work_item: WorkItems.render(work_item)}, effects}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call) do
    case WorkItems.reconcile_call(call.call_id) do
      {:ok, work_item, event} ->
        {:ok, %{work_item: WorkItems.render(work_item)},
         [effect("work_item_created", work_item, event)]}

      :retry ->
        case WorkItems.get_by_source(call.arguments["source"], call.arguments["external_key"]) do
          nil -> :retry
          work_item -> {:ok, %{work_item: WorkItems.render(work_item)}, []}
        end
    end
  end

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "create_work_item",
       source: arguments.source,
       external_key: arguments.external_key
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

  defp scope(envelope),
    do: "work:#{envelope.arguments.source}:#{envelope.arguments.external_key}"

  defp audit(arguments),
    do: "create work item #{arguments.source}:#{arguments.external_key}"
end
