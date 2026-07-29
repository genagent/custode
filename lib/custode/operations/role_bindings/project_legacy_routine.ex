defmodule Custode.Operations.RoleBindings.ProjectLegacyRoutine do
  @moduledoc false

  alias Custode.{
    LegacyRoleBindingProjection,
    OperationDefinition,
    OperationDispatcher,
    RoleBindings
  }

  alias Custode.Operations.Authorization

  @name "role_binding.project_legacy_routine"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          legacy_routine_id: [type: :string, required: true],
          mission_id: [type: :string, required: true],
          key: [type: :string, required: true],
          template_key: [type: :string, required: true],
          template_version: [type: :string, required: true],
          scoped_overrides: [type: :map, required: true],
          grants: [type: :map, required: true],
          provenance: [type: :map, required: true],
          projection_fingerprint: [type: :string, required: true]
        },
        result_schema: %{binding: [type: :map, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Project legacy routine into a role binding"}
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
      mission_id: observation[:mission_id] || observation["mission_id"],
      idempotency_key: "projection:#{LegacyRoleBindingProjection.fingerprint(observation)}",
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp handle(arguments, _envelope) do
    case RoleBindings.project_legacy(arguments) do
      {:ok, binding, effects} -> {:ok, %{binding: RoleBindings.render(binding)}, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(call), do: RoleBindings.reconcile_legacy(call.arguments)

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "project_legacy_role_binding",
       legacy_routine_id: arguments.legacy_routine_id,
       mission_id: arguments.mission_id,
       template_key: arguments.template_key
     }}
  end

  defp scope(envelope), do: "legacy-routine:#{envelope.arguments.legacy_routine_id}"
  defp audit(arguments), do: "project legacy role binding #{arguments.legacy_routine_id}"
end
