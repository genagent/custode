defmodule Custode.Operations.RoleBindings.Update do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, RoleBindings}
  alias Custode.Operations.Authorization

  @name "role_binding.update"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          binding_id: [type: :string, required: true],
          template_key: [type: :string],
          scoped_overrides: [type: :map],
          grants: [type: :map],
          lifecycle: [type: :string]
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
        projection: %{title: "Update role binding"}
      )

    definition
  end

  def dispatch(binding_id, attrs, options) do
    arguments = attrs |> Map.new() |> Map.put(:binding_id, binding_id)
    binding = RoleBindings.get(binding_id)

    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: arguments,
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      mission_id: binding && binding.mission.mission_id,
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      correlation_id: options[:correlation_id],
      causation_id: options[:causation_id],
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp handle(arguments, envelope) do
    attrs = Map.delete(arguments, :binding_id)

    case RoleBindings.update_database(arguments.binding_id, attrs, envelope.actor) do
      {:ok, binding} ->
        {:ok, %{binding: RoleBindings.render(binding)},
         [%{type: "role_binding_updated", binding_id: binding.binding_id}]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp preview(arguments, _envelope),
    do: {:ok, %{effect: "update_role_binding", binding_id: arguments.binding_id}}

  defp reconcile(call) do
    case RoleBindings.get(call.arguments["binding_id"]) do
      nil ->
        :retry

      binding ->
        if applied?(binding, call.arguments) do
          {:ok, %{binding: RoleBindings.render(binding)},
           [%{type: "role_binding_updated", binding_id: binding.binding_id}]}
        else
          :retry
        end
    end
  end

  defp applied?(binding, arguments) do
    Enum.all?(
      [
        {"template_key", binding.template_key},
        {"scoped_overrides", binding.scoped_overrides},
        {"grants", binding.grants},
        {"lifecycle", binding.lifecycle}
      ],
      fn {field, current} ->
        not Map.has_key?(arguments, field) or arguments[field] == current
      end
    )
  end

  defp scope(envelope), do: "role-binding:#{envelope.arguments.binding_id}"
  defp audit(arguments), do: "update role binding #{arguments.binding_id}"
end
