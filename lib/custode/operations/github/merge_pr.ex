defmodule Custode.Operations.GitHub.MergePr do
  @moduledoc false

  alias Custode.{GitHubMerge, OperationDefinition}

  @name "github.merge_pr"

  def definition do
    {:ok, definition} =
      OperationDefinition.new(
        name: @name,
        input_schema: %{
          work_item_id: [type: :string, required: true],
          gate_id: [type: :string, required: true],
          lease_id: [type: :string, required: true],
          repository: [type: :string, required: true],
          pull_request_number: [type: :integer, required: true],
          expected_version: [type: :integer, required: true],
          expected_head_sha: [type: :string, required: true],
          policy_version: [type: :string, required: true],
          external_preconditions: [type: :map, required: true]
        },
        result_schema: %{
          work_item: [type: :map, required: true],
          pull_request: [type: :map, required: true],
          lease: [type: :map, required: true],
          cleanup: [type: :map, required: true]
        },
        classification: :command,
        risk: :external_write,
        required_grants: [:operator, :system],
        authorization: &GitHubMerge.authorization/2,
        idempotency: %{required: true, scope: &scope/1},
        effect_preview: &preview/2,
        precondition: &GitHubMerge.precondition/2,
        reconcile: &GitHubMerge.reconcile/1,
        handler: &GitHubMerge.execute/2,
        audit: &audit/1,
        projection: %{title: "Merge pinned WorkItem pull request"}
      )

    definition
  end

  defp preview(arguments, _envelope) do
    {:ok,
     %{
       effect: "merge_pull_request",
       repository: arguments.repository,
       pull_request_number: arguments.pull_request_number,
       expected_head_sha: arguments.expected_head_sha,
       merge_method: merge_method(arguments),
       gate_id: arguments.gate_id
     }}
  end

  defp scope(envelope), do: "github-merge:#{envelope.arguments.work_item_id}"

  defp audit(arguments) do
    "merge PR ##{arguments.pull_request_number} on #{arguments.repository} " <>
      "at #{arguments.expected_head_sha}" <> by_method(merge_method(arguments))
  end

  defp by_method(nil), do: ""
  defp by_method(method), do: " by #{method}"

  defp merge_method(%{external_preconditions: %{} = external}),
    do: Map.get(external, "merge_method") || Map.get(external, :merge_method)

  defp merge_method(_arguments), do: nil
end
