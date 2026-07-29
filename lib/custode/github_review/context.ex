defmodule Custode.GitHubReview.Context do
  @moduledoc """
  Reproducible, bounded repair input compiled from one accepted GitHub
  observation and the publication Attempt that produced its pinned head.
  """

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundles,
    GitHubIssueContext,
    WorkspaceLease,
    WorkspaceLeases
  }

  alias Custode.Repair.{Disposition, Handlers, Policy}
  alias Custode.Verification.CommandSpec
  alias Custode.Workspace.Git

  @doc "Compile the exact mechanical or semantic response to accepted review evidence."
  def plan(routine, work_item, %WorkspaceLease{} = lease, options \\ []) do
    with {:ok, event, evidence} <- latest_observation(work_item),
         %Attempt{} = source <- publication_attempt(work_item.work_item_id, evidence),
         %Artifact{} = artifact <- Artifacts.get(evidence["artifact_id"]),
         :ok <- artifact_scope(artifact, work_item, evidence),
         {:ok, observation_body} <- read_observation(artifact),
         :ok <- Git.ownership(lease.repository_path, lease.workspace_path),
         {:ok, true} <- Git.clean?(lease.workspace_path),
         {:ok, workspace_revision} <- Git.workspace_revision(lease.workspace_path),
         :ok <- expected_head(workspace_revision, evidence),
         {:ok, disposition} <- disposition(source, artifact, evidence),
         {:ok, policy} <- policy(routine, options),
         decision <-
           Policy.authorize(
             disposition,
             Attempts.list_for_work_item(work_item.work_item_id),
             work_item,
             policy,
             Keyword.get(options, :repair_now, DateTime.utc_now())
           ) do
      prepare(decision, %{
        routine: routine,
        work_item: work_item,
        lease: lease,
        source: source,
        artifact: artifact,
        observation_body: observation_body,
        event: event,
        evidence: evidence,
        workspace_revision: workspace_revision,
        options: options
      })
    else
      nil -> {:error, :github_review_publication_attempt_missing}
      {:ok, false} -> {:error, :github_review_workspace_dirty}
      {:error, _reason} = error -> error
    end
  end

  defp prepare(
         {:exhausted, disposition, policy_snapshot, limit},
         %{work_item: work_item, artifact: artifact, evidence: evidence}
       ) do
    {:ok,
     %{
       kind: :transition,
       disposition: disposition,
       policy_snapshot: policy_snapshot,
       transition: %{
         state: "blocked",
         phase: work_item.phase,
         blocked_reason: %{
           code: "repair_policy_exhausted",
           disposition: disposition.kind,
           reason: disposition.reason,
           observation_artifact_id: artifact.artifact_id,
           limit: limit
         },
         evidence: %{
           github_observation: evidence,
           repair_disposition: Disposition.render(disposition),
           repair_policy: policy_snapshot,
           limit: limit
         }
       }
     }}
  end

  defp prepare({:ok, disposition, policy_snapshot}, scope) do
    with {:ok, handler_options} <-
           handler_options(disposition, scope.lease, scope.evidence),
         {:ok, handler} <- Handlers.fetch(disposition.handler, handler_options),
         {:ok, source_body} <- ContextBundles.body(scope.source.context_bundle),
         body <-
           context_body(
             source_body,
             scope,
             disposition,
             policy_snapshot,
             handler
           ),
         {:ok, {_status, bundle}} <-
           ContextBundles.create(
             scope.work_item.work_item_id,
             body,
             artifact_options(scope.options,
               provenance: %{
                 compiler: "github_review_context",
                 purpose: "review_repair",
                 legacy_routine_id: scope.routine.id,
                 source_attempt_id: scope.source.attempt_id,
                 source_event_id: scope.event.event_id,
                 observation_artifact_id: scope.artifact.artifact_id,
                 observation_external_identity: scope.artifact.external_identity,
                 repair_disposition: Disposition.render(disposition),
                 repair_policy: policy_snapshot,
                 workspace_lease_id: scope.lease.lease_id,
                 workspace_revision: scope.workspace_revision["revision"],
                 active_phase: scope.evidence["action"]["active_phase"]
               }
             )
           ) do
      {:ok,
       %{
         kind: :attempt,
         source_attempt: scope.source,
         source_event: scope.event,
         observation_artifact: scope.artifact,
         observation: scope.observation_body,
         observation_evidence: scope.evidence,
         disposition: disposition,
         policy_snapshot: policy_snapshot,
         handler: handler,
         bundle: bundle,
         body: body,
         workspace_revision: scope.workspace_revision
       }}
    end
  end

  defp latest_observation(work_item) do
    work_item.work_item_id
    |> Custode.WorkItems.list_events()
    |> Enum.reverse()
    |> Enum.find_value(fn event ->
      evidence = event.evidence || %{}

      if is_map(evidence["review_repair"]) and is_map(evidence["github_observation"]) do
        {:ok, event, evidence["github_observation"]}
      end
    end)
    |> case do
      nil -> {:error, :github_review_observation_missing}
      result -> result
    end
  end

  defp publication_attempt(work_item_id, evidence) do
    work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(fn attempt ->
      get_in(attempt.provenance || %{}, ["purpose"]) == "github_issue_publication" and
        get_in(attempt.outcome || %{}, ["pull_request", "head_sha"]) == evidence["head_sha"]
    end)
  end

  defp artifact_scope(artifact, work_item, evidence) do
    valid? =
      artifact.kind == "github_observation" and
        artifact.work_item.work_item_id == work_item.work_item_id and
        artifact.artifact_id == evidence["artifact_id"] and
        artifact.external_identity == evidence["external_identity"] and
        (artifact.provenance["accepted"] || artifact.provenance[:accepted])

    if valid?, do: :ok, else: {:error, :github_review_observation_scope_mismatch}
  end

  defp read_observation(artifact) do
    with {:ok, encoded} <- File.read(artifact.location),
         true <- Artifacts.digest(encoded) == artifact.digest,
         {:ok, body} <- Jason.decode(encoded) do
      {:ok, body}
    else
      false -> {:error, :github_review_observation_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp expected_head(workspace_revision, evidence) do
    if workspace_revision["head_revision"] == evidence["head_sha"] do
      :ok
    else
      {:error,
       {:github_review_workspace_head_changed,
        %{expected: evidence["head_sha"], observed: workspace_revision["head_revision"]}}}
    end
  end

  defp disposition(source, artifact, evidence) do
    action = evidence["action"]

    Disposition.new(%{
      kind: action["disposition"],
      reason: action["reason"],
      source_attempt_id: source.attempt_id,
      failure_artifact_id: artifact.artifact_id,
      handler: action["handler"]
    })
  end

  defp handler_options(%{handler: "git_replay"}, lease, evidence) do
    head_revision = evidence["head_sha"]
    new_base_revision = evidence["base_sha"]

    with true <- is_binary(new_base_revision),
         :ok <- Git.fetch_commit(lease.repository_path, "origin", new_base_revision),
         {:ok, ^new_base_revision} <- Git.revision(lease.repository_path, new_base_revision),
         {:ok, old_base_revision} <- Git.commit_parent(lease.repository_path, head_revision) do
      {:ok,
       [
         repository_path: lease.repository_path,
         old_base_revision: old_base_revision,
         new_base_revision: new_base_revision,
         head_revision: head_revision
       ]}
    else
      false -> {:error, :github_review_base_revision_missing}
      {:ok, observed} -> {:error, {:github_review_base_revision_changed, observed}}
      {:error, _reason} = error -> error
    end
  end

  defp handler_options(_disposition, lease, _evidence),
    do: {:ok, [repository_path: lease.repository_path]}

  defp context_body(source_body, scope, disposition, policy_snapshot, handler) do
    source_body
    |> Map.put(
      "recipe",
      source_body
      |> Map.get("recipe", %{})
      |> Map.put("repair", render_handler(handler))
      |> Map.put("repair_policy_version", policy_snapshot.policy.version)
    )
    |> Map.put(
      "prior_evidence",
      Map.get(source_body, "prior_evidence", []) ++ [attempt_evidence(scope.source)]
    )
    |> Map.put("github_observation", %{
      "artifact" => Artifacts.render(scope.artifact),
      "evidence" => scope.evidence,
      "body" => scope.observation_body
    })
    |> Map.put("repair", %{
      "disposition" => Disposition.render(disposition),
      "policy" => policy_snapshot,
      "failure_artifact" => Artifacts.render(scope.artifact),
      "focused_failure" => scope.observation_body
    })
    |> Map.put(
      "workspace_revision",
      scope.lease
      |> WorkspaceLeases.render()
      |> Map.merge(scope.workspace_revision)
    )
    |> Map.put("capabilities", capabilities(disposition))
    |> Map.put("output_contract", output_contract(disposition))
  end

  defp capabilities(%{kind: "semantic_repair"}),
    do: %{"tools" => GitHubIssueContext.allowed_tools(), "operations" => []}

  defp capabilities(_disposition), do: %{"tools" => [], "operations" => []}

  defp output_contract(%{kind: "semantic_repair"}), do: GitHubIssueContext.output_contract()

  defp output_contract(_disposition) do
    %{
      "kind" => "deterministic_repair",
      "result_statuses" => [
        "pass",
        "test_failure",
        "policy_refusal",
        "timeout",
        "infrastructure_error",
        "cancellation"
      ]
    }
  end

  defp render_handler(:claude),
    do: %{"name" => "claude", "version" => "github_issue_review_repair_v1"}

  defp render_handler(%CommandSpec{} = spec), do: CommandSpec.render(spec)

  defp attempt_evidence(attempt) do
    %{
      "attempt_id" => attempt.attempt_id,
      "context_bundle_id" => attempt.context_bundle.context_bundle_id,
      "context_digest" => attempt.context_digest,
      "state" => attempt.state,
      "usage" => attempt.usage,
      "outcome" => attempt.outcome,
      "finished_at" => attempt.finished_at && DateTime.to_iso8601(attempt.finished_at)
    }
  end

  defp policy(routine, options) do
    default = Policy.default(routine)

    case Keyword.get(options, :repair_policy) do
      %Policy{} = policy ->
        {:ok, policy}

      nil ->
        {:ok, default}

      attrs when is_map(attrs) or is_list(attrs) ->
        attrs =
          default
          |> Policy.render()
          |> Map.merge(policy_overrides(attrs))

        Policy.new(attrs)

      _invalid ->
        {:error, :invalid_repair_policy}
    end
  end

  defp policy_overrides(attrs) do
    Map.new(attrs, fn
      {"version", value} -> {:version, value}
      {"max_infrastructure_retries", value} -> {:max_infrastructure_retries, value}
      {"max_repairs", value} -> {:max_repairs, value}
      {"max_elapsed_ms", value} -> {:max_elapsed_ms, value}
      {"max_spend_usd", value} -> {:max_spend_usd, value}
      pair -> pair
    end)
  end

  defp artifact_options(options, provenance: provenance) do
    [
      artifact_dir: Keyword.get(options, :artifact_dir),
      provenance: provenance,
      retention: %{until: "work_item_terminal"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end
end
