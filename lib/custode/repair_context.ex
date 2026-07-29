defmodule Custode.RepairContext do
  @moduledoc """
  Reproducible repair planning from one preserved failed Attempt and its
  focused evidence.
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

  @doc "Classify one repair-ready WorkItem and prepare its exact next decision."
  def plan(routine, work_item, %WorkspaceLease{} = lease, options \\ []) do
    with %Attempt{} = failed <- failed_attempt(work_item.work_item_id),
         {:ok, failure_artifact, focused_failure} <-
           focused_failure(failed, work_item.work_item_id, lease),
         {:ok, policy} <- policy(routine, options),
         now <- Keyword.get(options, :repair_now, DateTime.utc_now()),
         attempts <- Attempts.list_for_work_item(work_item.work_item_id),
         decision <-
           Policy.evaluate(failed, focused_failure, attempts, work_item, policy, now) do
      prepare_decision(
        decision,
        routine,
        work_item,
        lease,
        failed,
        failure_artifact,
        focused_failure,
        options
      )
    else
      nil -> {:error, {:repair_source_attempt_missing, work_item.work_item_id}}
      {:error, _reason} = error -> error
    end
  end

  defp prepare_decision(
         {:ok, %Disposition{kind: "human_ask"} = disposition, policy_snapshot},
         _routine,
         work_item,
         _lease,
         _failed,
         _artifact,
         _focused,
         _options
       ) do
    {:ok,
     %{
       kind: :transition,
       disposition: disposition,
       policy_snapshot: policy_snapshot,
       transition: %{
         state: "waiting",
         phase: work_item.phase,
         waiting_condition: %{
           kind: "external_event",
           name: "operator_answer",
           question: disposition.question,
           source_attempt_id: disposition.source_attempt_id
         },
         evidence: decision_evidence(disposition, policy_snapshot)
       }
     }}
  end

  defp prepare_decision(
         {:ok, %Disposition{kind: "terminal_block"} = disposition, policy_snapshot},
         _routine,
         work_item,
         _lease,
         _failed,
         _artifact,
         _focused,
         _options
       ) do
    {:ok, blocked_plan(work_item, disposition, policy_snapshot, nil)}
  end

  defp prepare_decision(
         {:exhausted, disposition, policy_snapshot, limit},
         _routine,
         work_item,
         _lease,
         _failed,
         _artifact,
         _focused,
         _options
       ) do
    {:ok, blocked_plan(work_item, disposition, policy_snapshot, limit)}
  end

  defp prepare_decision(
         {:ok, disposition, policy_snapshot},
         routine,
         work_item,
         lease,
         failed,
         failure_artifact,
         focused_failure,
         options
       ) do
    with {:ok, handler} <-
           Handlers.fetch(
             disposition.handler,
             repository_path: lease.repository_path
           ),
         {:ok, source_body} <- ContextBundles.body(failed.context_bundle),
         {:ok, workspace_revision} <- Git.workspace_revision(lease.workspace_path),
         body <-
           repair_body(
             source_body,
             failed,
             failure_artifact,
             focused_failure,
             %{
               disposition: disposition,
               policy_snapshot: policy_snapshot,
               lease: lease,
               workspace_revision: workspace_revision,
               handler: handler
             }
           ),
         {:ok, {_status, bundle}} <-
           ContextBundles.create(
             work_item.work_item_id,
             body,
             artifact_options(options,
               provenance: %{
                 compiler: "repair_context",
                 purpose: "repair",
                 legacy_routine_id: routine.id,
                 source_attempt_id: failed.attempt_id,
                 failure_artifact_id: failure_artifact.artifact_id,
                 repair_disposition: Disposition.render(disposition),
                 repair_policy: policy_snapshot,
                 workspace_lease_id: lease.lease_id,
                 workspace_revision: workspace_revision["revision"]
               }
             )
           ) do
      {:ok,
       %{
         kind: :attempt,
         disposition: disposition,
         policy_snapshot: policy_snapshot,
         source_attempt: failed,
         failure_artifact: failure_artifact,
         focused_failure: focused_failure,
         bundle: bundle,
         body: body,
         handler: handler,
         workspace_revision: workspace_revision
       }}
    end
  end

  defp blocked_plan(work_item, disposition, policy_snapshot, limit) do
    code = if limit, do: "repair_policy_exhausted", else: "repair_terminal_block"

    %{
      kind: :transition,
      disposition: disposition,
      policy_snapshot: policy_snapshot,
      transition: %{
        state: "blocked",
        phase: work_item.phase,
        blocked_reason:
          %{
            code: code,
            disposition: disposition.kind,
            reason: disposition.reason,
            source_attempt_id: disposition.source_attempt_id
          }
          |> maybe_put(:limit, limit),
        evidence: decision_evidence(disposition, policy_snapshot) |> maybe_put(:limit, limit)
      }
    }
  end

  defp decision_evidence(disposition, policy_snapshot) do
    %{
      repair_disposition: Disposition.render(disposition),
      repair_policy: policy_snapshot
    }
  end

  defp failed_attempt(work_item_id) do
    work_item_id
    |> Attempts.list_for_work_item()
    |> Enum.reverse()
    |> Enum.find(fn attempt ->
      Attempt.terminal?(attempt) and
        get_in(attempt.outcome || %{}, ["proposal", "phase"]) == "repair_ready"
    end)
  end

  defp focused_failure(failed, work_item_id, lease) do
    artifact_id =
      get_in(failed.outcome || %{}, ["artifacts", "failure_artifact_id"]) ||
        get_in(failed.outcome || %{}, ["artifacts", "provider_checkpoint_artifact_id"]) ||
        get_in(failed.outcome || %{}, ["artifacts", "repair_result_artifact_id"])

    with artifact_id when is_binary(artifact_id) <- artifact_id,
         %Artifact{} = artifact <- Artifacts.get(artifact_id),
         :ok <- failure_scope(artifact, failed, work_item_id),
         {:ok, encoded} <- File.read(artifact.location),
         true <- Artifacts.digest(encoded) == artifact.digest,
         {:ok, body} <- Jason.decode(encoded),
         :ok <- failure_workspace_matches(artifact, body, lease) do
      {:ok, artifact, focus(artifact, body)}
    else
      nil -> {:error, :focused_failure_artifact_missing}
      false -> {:error, :focused_failure_artifact_digest_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :focused_failure_artifact_invalid}
    end
  end

  defp failure_scope(artifact, failed, work_item_id) do
    producer = artifact.producer_attempt && artifact.producer_attempt.attempt_id
    owner = artifact.work_item.work_item_id

    if producer == failed.attempt_id and owner == work_item_id,
      do: :ok,
      else: {:error, :focused_failure_artifact_scope_mismatch}
  end

  defp failure_workspace_matches(%{kind: "verification_failure"}, body, lease) do
    compare_workspace_revision(body["workspace_revision"], lease.workspace_path)
  end

  defp failure_workspace_matches(%{kind: "repair_result"}, body, lease) do
    body
    |> get_in(["workspace_revision_after", "revision"])
    |> compare_workspace_revision(lease.workspace_path)
  end

  defp failure_workspace_matches(%{kind: "provider_result"}, body, lease) do
    with {:ok, changed_files} <- Git.changed_files(lease.workspace_path),
         {:ok, diff} <- Git.diff(lease.workspace_path) do
      if changed_files == body["changed_files"] and diff == body["diff"],
        do: :ok,
        else: {:error, :focused_failure_workspace_changed}
    end
  end

  defp failure_workspace_matches(_artifact, _body, _lease),
    do: {:error, :focused_failure_artifact_kind_unsupported}

  defp compare_workspace_revision(expected, workspace_path) when is_binary(expected) do
    with {:ok, observed} <- Git.workspace_revision(workspace_path) do
      if observed["revision"] == expected,
        do: :ok,
        else: {:error, :focused_failure_workspace_changed}
    end
  end

  defp compare_workspace_revision(_expected, _workspace_path),
    do: {:error, :focused_failure_workspace_revision_missing}

  defp focus(%{kind: "verification_failure"} = artifact, body),
    do: Map.put(body, "artifact_id", artifact.artifact_id)

  defp focus(%{kind: "provider_result"} = artifact, body) do
    %{
      "artifact_id" => artifact.artifact_id,
      "classification" => body["classification"],
      "changed_files" => body["changed_files"],
      "provider" =>
        body
        |> Map.get("provider", %{})
        |> Map.take(["structured_output", "result", "stop_reason"])
    }
  end

  defp focus(%{kind: "repair_result"} = artifact, body) do
    body
    |> Map.take([
      "attempt_id",
      "disposition",
      "status",
      "reason",
      "exit_code",
      "duration_ms",
      "stdout_tail",
      "stderr_tail",
      "stdout_truncated",
      "stderr_truncated"
    ])
    |> Map.put("artifact_id", artifact.artifact_id)
  end

  defp focus(artifact, body),
    do: %{"artifact_id" => artifact.artifact_id, "kind" => artifact.kind, "body" => body}

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

  defp repair_body(body, failed, failure_artifact, focused_failure, repair) do
    disposition = repair.disposition
    policy_snapshot = repair.policy_snapshot

    body
    |> Map.put(
      "recipe",
      body
      |> Map.get("recipe", %{})
      |> Map.put("repair", render_handler(repair.handler))
      |> Map.put("repair_policy_version", policy_snapshot.policy.version)
    )
    |> Map.put(
      "prior_evidence",
      Map.get(body, "prior_evidence", []) ++ [attempt_evidence(failed)]
    )
    |> Map.put("repair", %{
      "disposition" => Disposition.render(disposition),
      "policy" => policy_snapshot,
      "failure_artifact" => Artifacts.render(failure_artifact),
      "focused_failure" => focused_failure
    })
    |> Map.put(
      "workspace_revision",
      repair.lease
      |> WorkspaceLeases.render()
      |> Map.take([
        :lease_id,
        :repository_id,
        :repository_path,
        :workspace_identity,
        :workspace_path,
        :branch,
        :base_ref,
        :expected_base_revision,
        :observed_base_revision,
        :landing_scope
      ])
      |> Map.merge(repair.workspace_revision)
    )
    |> Map.put("capabilities", repair_capabilities(disposition))
    |> Map.put("output_contract", repair_output_contract(disposition))
  end

  defp repair_capabilities(%{kind: "semantic_repair"}),
    do: %{"tools" => GitHubIssueContext.allowed_tools(), "operations" => []}

  defp repair_capabilities(_disposition), do: %{"tools" => [], "operations" => []}

  defp repair_output_contract(%{kind: "semantic_repair"}),
    do: GitHubIssueContext.output_contract()

  defp repair_output_contract(_disposition) do
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

  defp render_handler(:verification_retry),
    do: %{"name" => "verification_retry", "version" => "1"}

  defp render_handler(:claude),
    do: %{"name" => "claude", "version" => "github_issue_repair_v1"}

  defp render_handler(%CommandSpec{} = spec), do: CommandSpec.render(spec)

  defp attempt_evidence(attempt) do
    %{
      "attempt_id" => attempt.attempt_id,
      "context_bundle_id" => attempt.context_bundle.context_bundle_id,
      "context_digest" => attempt.context_digest,
      "state" => attempt.state,
      "usage" => attempt.usage,
      "outcome" => attempt.outcome,
      "error_class" => attempt.error_class,
      "finished_at" => attempt.finished_at && DateTime.to_iso8601(attempt.finished_at)
    }
  end

  defp artifact_options(options, provenance: provenance) do
    [
      artifact_dir: Keyword.get(options, :artifact_dir),
      provenance: provenance,
      retention: %{until: "work_item_terminal"}
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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
end
