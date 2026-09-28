defmodule Custode.Operations.GitHub.OpenPr do
  @moduledoc false

  alias Custode.{OperationDefinition, OperationDispatcher}
  alias Custode.Operations.Authorization
  alias Custode.Publication.GitHub

  @name "github.open_pr"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          work_item_id: [type: :string, required: true],
          attempt_id: [type: :string, required: true],
          lease_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          remote: [type: :string, required: true],
          expected_work_item_version: [type: :integer, required: true],
          expected_head_sha: [type: :string, required: true],
          head_branch: [type: :string, required: true],
          base_branch: [type: :string, required: true],
          title: [type: :string, required: true],
          body: [type: :string, required: true]
        },
        result_schema: %{
          work_item_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          number: [type: :integer, required: true],
          url: [type: :string, required: true],
          state: [type: :string, required: true],
          draft: [type: :boolean, required: true],
          base_branch: [type: :string, required: true],
          head_branch: [type: :string, required: true],
          head_sha: [type: :string, required: true],
          source: [type: :string, required: true]
        },
        classification: :command,
        risk: :external_write,
        required_grants: [:system],
        authorization: &Authorization.system/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        precondition: &GitHub.precondition/2,
        reconcile: &reconcile/1,
        handler: &handle/2,
        audit: &audit/1,
        projection: %{title: "Open WorkItem draft pull request"}
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

  defp handle(arguments, envelope) do
    case GitHub.open(arguments, envelope.actor) do
      {:ok, result, effects} -> {:ok, result, effects}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile(call), do: GitHub.reconcile(call.arguments)

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "open_draft_pull_request",
       repository: arguments.repository,
       head_branch: arguments.head_branch,
       base_branch: arguments.base_branch,
       expected_head_sha: arguments.expected_head_sha,
       draft: true
     }}
  end

  defp scope(envelope), do: "publication:#{envelope.arguments.work_item_id}"
  defp audit(arguments), do: "open draft PR for #{arguments.repository}:#{arguments.head_branch}"

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
