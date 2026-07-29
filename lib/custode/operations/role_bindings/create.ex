defmodule Custode.Operations.RoleBindings.Create do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, RoleBindings}
  alias Custode.Operations.Authorization

  @name "role_binding.create"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          mission_id: [type: :string, required: true],
          key: [type: :string, required: true],
          template_key: [type: :string, required: true],
          scoped_overrides: [type: :map],
          grants: [type: :map]
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
        projection: %{title: "Create role binding"}
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
    case RoleBindings.create_database(arguments, envelope.actor) do
      {:ok, {status, binding}} ->
        effects =
          if status == :created,
            do: [%{type: "role_binding_created", binding_id: binding.binding_id}],
            else: []

        {:ok, %{binding: RoleBindings.render(binding)}, effects}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp reconcile(call) do
    expected_template_key = call.arguments["template_key"]

    case RoleBindings.get_by_key(call.arguments["mission_id"], call.arguments["key"]) do
      %{authority_source: "database", template_key: template_key} = binding
      when template_key == expected_template_key ->
        {:ok, %{binding: RoleBindings.render(binding)}, []}

      _missing_or_conflicting ->
        :retry
    end
  end

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "create_role_binding",
       mission_id: arguments.mission_id,
       key: arguments.key,
       template_key: arguments.template_key
     }}
  end

  defp scope(envelope),
    do: "mission:#{envelope.arguments.mission_id}:binding:#{envelope.arguments.key}"

  defp audit(arguments), do: "create role binding #{arguments.key}"
end
