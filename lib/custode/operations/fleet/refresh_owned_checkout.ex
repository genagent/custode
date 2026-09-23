defmodule Custode.Operations.Fleet.RefreshOwnedCheckout do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher, OwnedCheckout, Routine}
  alias Custode.Operations.Authorization

  @name "fleet.refresh_owned_checkout"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{routine_id: [type: :string, required: true]},
        result_schema: %{
          routine_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          path: [type: :string, required: true],
          status: [type: :string, required: true],
          branch: [type: :string, required: true],
          commits: [type: :integer, required: true]
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
          title: "Refresh owned checkout",
          description: "Fetch and safely fast-forward a routine-owned checkout.",
          mcp: %{name: "refresh_owned_checkout"}
        }
      )

    definition
  end

  def dispatch(routine_id, options) do
    OperationDispatcher.dispatch(%{
      operation: @name,
      arguments: %{routine_id: routine_id},
      actor: Keyword.fetch!(options, :actor),
      transport: Keyword.fetch!(options, :transport),
      idempotency_key: Keyword.fetch!(options, :idempotency_key),
      dry_run: Keyword.get(options, :dry_run, false)
    })
  end

  defp preview(%{routine_id: id}, _envelope) do
    with {:ok, routine, path} <- owned_routine(id) do
      {:ok,
       %{
         effect: "refresh_owned_checkout",
         routine_id: id,
         repository: routine.repo,
         path: path,
         may: ["fetch", "fast-forward"]
       }}
    end
  end

  defp handle(%{routine_id: id}, _envelope) do
    with {:ok, routine, _path} <- owned_routine(id),
         {:ok, result} <- OwnedCheckout.refresh(id, routine.repo) do
      rendered = render(id, result)
      {:ok, rendered, [%{type: "owned_checkout_refreshed"} |> Map.merge(rendered)]}
    end
  end

  defp reconcile(_call), do: :retry

  defp owned_routine(id) do
    case Routine.get(id) do
      nil ->
        {:error, %{kind: :routine_not_found, routine_id: id}}

      %{repo: repository} = routine when is_binary(repository) ->
        owned_path(routine, id)

      _routine ->
        {:error, %{kind: :repository_required, routine_id: id}}
    end
  end

  defp owned_path(routine, id) do
    case OwnedCheckout.path(id) do
      {:ok, path} -> require_owned_path(routine, id, path)
      {:error, reason} -> {:error, %{kind: reason, routine_id: id}}
    end
  end

  defp require_owned_path(routine, id, path) do
    if Path.expand(routine.working_dir) == path do
      {:ok, routine, path}
    else
      {:error, %{kind: :existing_checkout_refused, routine_id: id}}
    end
  end

  defp render(id, result) do
    %{
      routine_id: id,
      repository: result.repo,
      path: result.path,
      status: to_string(result.status),
      branch: result.branch,
      commits: result.commits
    }
  end

  defp scope(envelope), do: "owned-checkout:#{envelope.arguments.routine_id}"
  defp audit(arguments), do: "refresh owned checkout for #{arguments.routine_id}"
end
