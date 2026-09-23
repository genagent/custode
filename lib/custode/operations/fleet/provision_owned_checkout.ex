defmodule Custode.Operations.Fleet.ProvisionOwnedCheckout do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, OwnedCheckout}
  alias Custode.Operations.Authorization

  @name "fleet.provision_owned_checkout"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          routine_id: [type: :string, required: true],
          repository: [type: :string, required: true]
        },
        result_schema: %{
          routine_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          path: [type: :string, required: true],
          status: [type: :string, required: true]
        },
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator],
        authorization: &Authorization.operator/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{
          title: "Provision owned checkout",
          description: "Clone a repository into a routine's deterministic Custode checkout.",
          mcp: %{name: "provision_owned_checkout"}
        }
      )

    definition
  end

  def dispatch(routine_id, repository, options) do
    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: %{routine_id: routine_id, repository: repository},
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp preview(%{routine_id: id, repository: repository}, _envelope) do
    with {:ok, path} <- OwnedCheckout.path(id) do
      {:ok,
       %{
         effect: "provision_owned_checkout",
         routine_id: id,
         repository: repository,
         path: path,
         may: ["clone"]
       }}
    end
  end

  defp handle(%{routine_id: id, repository: repository}, _envelope) do
    case OwnedCheckout.provision(id, repository) do
      {:ok, result} -> {:ok, render(id, result), [effect(id, result)]}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(call) do
    id = call.arguments["routine_id"]
    repository = call.arguments["repository"]

    with {:ok, path} <- OwnedCheckout.path(id),
         {:ok, %{state: :matching}} <- OwnedCheckout.inspect_destination(path, repository) do
      result = %{status: :already_provisioned, path: path, repo: repository}
      {:ok, render(id, result), [effect(id, result)]}
    else
      _not_complete -> :retry
    end
  end

  defp render(id, result) do
    %{
      routine_id: id,
      repository: result.repo,
      path: result.path,
      status: to_string(result.status)
    }
  end

  defp effect(id, result) do
    %{
      type: "owned_checkout_provisioned",
      routine_id: id,
      repository: result.repo,
      path: result.path
    }
  end

  defp scope(envelope), do: "owned-checkout:#{envelope.arguments.routine_id}"
  defp audit(arguments), do: "provision owned checkout for #{arguments.routine_id}"
end
