defmodule Custode.Operations.Git.PublishBranch do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization
  alias Custode.Publication.Git

  @name "git.publish_branch"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          work_item_id: [type: :string, required: true],
          attempt_id: [type: :string, required: true],
          lease_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          repository_path: [type: :string, required: true],
          workspace_path: [type: :string, required: true],
          branch: [type: :string, required: true],
          remote: [type: :string, required: true],
          expected_work_item_version: [type: :integer, required: true],
          expected_workspace_revision: [type: :string, required: true],
          expected_head_revision: [type: :string, required: true],
          expected_changed_files: [type: :list, required: true],
          commit_message: [type: :string, required: true]
        },
        result_schema: %{
          work_item_id: [type: :string, required: true],
          lease_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          branch: [type: :string, required: true],
          remote: [type: :string, required: true],
          commit_sha: [type: :string, required: true],
          source: [type: :string, required: true]
        },
        classification: :command,
        risk: :external_write,
        required_grants: [:system],
        authorization: &Authorization.system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        precondition: &Git.precondition/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Publish verified WorkItem branch"}
      )

    definition
  end

  def dispatch(arguments, options) do
    arguments = Map.new(arguments)

    OperationDispatcher.dispatch(
      %{
        operation: @name,
        arguments: arguments,
        actor: %{kind: :system, id: "github-issue-publication"},
        transport: :worker,
        mission_id: Keyword.fetch!(options, :mission_id),
        work_item_id: value(arguments, :work_item_id),
        attempt_id: value(arguments, :attempt_id),
        expected_versions: %{work_item: value(arguments, :expected_work_item_version)},
        idempotency_key: Keyword.fetch!(options, :idempotency_key),
        correlation_id: options[:correlation_id],
        causation_id: options[:causation_id]
      },
      Keyword.get(options, :registry, Custode.OperationRegistry.default())
    )
  end

  defp handle(arguments, _envelope) do
    case Git.publish(arguments) do
      {:ok, result, effects} -> {:ok, result, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(call), do: Git.reconcile(call.arguments)

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "publish_git_branch",
       repository: arguments.repository,
       branch: arguments.branch,
       remote: arguments.remote,
       expected_workspace_revision: arguments.expected_workspace_revision
     }}
  end

  defp scope(envelope), do: "publication:#{envelope.arguments.work_item_id}"
  defp audit(arguments), do: "publish #{arguments.repository}:#{arguments.branch}"

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
