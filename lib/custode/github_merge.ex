defmodule Custode.GitHubMerge do
  @moduledoc """
  Exact, operator-gated completion of the GitHub issue-to-merge vertical.

  The legacy `Repository.merge_pr/2` policy remains unchanged. This module is
  the narrower work-first seam: it pins the WorkItem version, policy, pull
  request head, checks, review evidence, and the merge method the repository
  allows (#674); activates the merge OperationCall; reconciles an
  already-landed external effect; completes the WorkItem once; and releases its
  workspace lease idempotently.

  The method is read with the review snapshot, so a repository settings change
  makes the Gate stale before any mutation.
  """

  alias Custode.{
    Artifact,
    OperationCall,
    OperationEnvelope,
    Repository,
    WorkGate,
    WorkGates,
    WorkItems,
    WorkPolicy,
    WorkspaceLease,
    WorkspaceLeases
  }

  alias Custode.GitHubReview.Observation
  alias Custode.Operations.Authorization
  alias Custode.Operations.WorkItems, as: WorkOperations

  @operation "github.merge_pr"
  @requester %{kind: :system, id: "github-review-reconciler"}

  @doc "Stable identity for the Gate protecting one pinned merge snapshot."
  def gate_id(work_item_id, external_preconditions) do
    digest =
      {work_item_id, external_preconditions}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "github-merge:#{digest}"
  end

  @doc "Create or replay the exact merge Gate after the WorkItem enters merge_ready."
  def propose(work_item_id, action, %Artifact{} = artifact, options) do
    with {:ok, work_item} <- fetch_work_item(work_item_id),
         {:ok, external} <- fetch_merge_preconditions(action),
         gate_id <- gate_id(work_item_id, external),
         :ok <- waiting_for_gate(work_item, gate_id),
         {:ok, lease} <- fetch_active_lease(work_item_id),
         {:ok, policy_version} <- fetch_policy_version(work_item),
         {:ok, policy} <-
           WorkPolicy.operation(work_item, :external_write, repository: external["repository"]),
         :ask <- policy.posture do
      arguments = %{
        work_item_id: work_item_id,
        gate_id: gate_id,
        lease_id: lease.lease_id,
        repository: external["repository"],
        pull_request_number: external["pull_request_number"],
        expected_version: work_item.version,
        expected_head_sha: external["head_sha"],
        policy_version: policy_version,
        external_preconditions: external
      }

      WorkGates.propose(
        %{
          gate_id: gate_id,
          work_item_id: work_item_id,
          subject_kind: "operation_call",
          operation: @operation,
          arguments: arguments,
          policy_version: policy_version,
          work_policy: WorkPolicy.render(policy),
          external_preconditions: external,
          operation_idempotency_key: "github-merge:#{work_item_id}:#{external["head_sha"]}",
          correlation_id: options[:correlation_id] || "github-merge:#{artifact.artifact_id}",
          causation_id: options[:causation_id] || artifact.external_identity
        },
        actor: @requester,
        transport: :worker,
        registry: Keyword.get(options, :registry, Custode.OperationRegistry.default())
      )
    else
      {:error, _reason} = error -> error
      posture -> {:error, {:merge_policy_requires_ask, posture}}
    end
  end

  @doc "Approve a merge Gate using a fresh policy and GitHub snapshot."
  def approve(gate_id, options) do
    with %WorkGate{} = gate <- WorkGates.get(gate_id),
         work_item when not is_nil(work_item) <- WorkItems.get(gate.work_item.work_item_id),
         {:ok, external} <- current_preconditions(gate.arguments),
         {:ok, policy} <-
           WorkPolicy.operation(work_item, :external_write,
             repository: gate.arguments["repository"]
           ) do
      WorkGates.approve(
        gate_id,
        %{
          policy_version: work_item.policy_ref,
          work_policy: WorkPolicy.render(policy),
          external_preconditions: external
        },
        actor: Keyword.fetch!(options, :actor),
        transport: Keyword.fetch!(options, :transport),
        registry: Keyword.get(options, :registry, Custode.OperationRegistry.default())
      )
    else
      nil -> {:error, {:unknown_gate, gate_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def authorization(_definition, %OperationEnvelope{
        actor: @requester,
        transport: :worker
      }),
      do: {:ok, :system}

  def authorization(definition, envelope), do: Authorization.operator(definition, envelope)

  @doc false
  def precondition(arguments, envelope) do
    with {:ok, work_item, lease} <- scope_references(arguments, envelope),
         {:ok, observation, current} <- current_snapshot(arguments),
         :ok <-
           execution_precondition(arguments, envelope, work_item, lease, observation, current) do
      :ok
    else
      {:error, reason} ->
        {:stale, reason, observed(arguments)}
    end
  end

  @doc false
  def execute(
        arguments,
        %OperationEnvelope{
          grant: :operator,
          call_id: call_id,
          gate_id: gate_id
        } = envelope
      )
      when is_binary(call_id) and is_binary(gate_id) do
    with true <- gate_id == value(arguments, :gate_id),
         {:ok, observation, current} <- current_snapshot(arguments),
         :ok <- expected_external(arguments, observation, current),
         {:ok, merged} <-
           Repository.merge_pr_at_head(
             value(arguments, :repository),
             value(arguments, :pull_request_number),
             value(arguments, :expected_head_sha),
             pinned_merge_method(arguments)
           ),
         :ok <- sent_pinned_method(merged, arguments),
         {:ok, merge_commit_sha} <- merge_commit(merged),
         finalization <- finalize(arguments, envelope, merge_commit_sha, "merged") do
      case finalization do
        {:ok, result, effects} ->
          {:ok, result, effects}

        {:error, reason} ->
          {:waiting, {:github_merge_finalization_pending, reason}}
      end
    else
      {:error, {:stale, _reason, _observed}} = error ->
        error

      {:error, reason} ->
        merge_failure(arguments, reason)

      false ->
        {:error, :operator_gate_required}
    end
  end

  def execute(_arguments, _envelope), do: {:error, :operator_gate_required}

  @doc false
  def reconcile(%OperationCall{} = call) do
    arguments = call.arguments

    case current_snapshot(arguments) do
      {:ok, _observation, current} ->
        reconcile_snapshot(call, arguments, current)

      {:error, reason} ->
        {:waiting, reason}
    end
  end

  defp reconcile_snapshot(call, arguments, current) do
    if merged_at_expected_head?(arguments, current) do
      reconcile_merged(call, arguments, current["pull_request"]["merge_commit_sha"])
    else
      :retry
    end
  end

  defp reconcile_merged(call, arguments, merge_commit_sha) do
    case finalize(arguments, reconcile_envelope(call, arguments), merge_commit_sha, "reconciled") do
      {:ok, result, effects} -> {:ok, result, effects}
      {:error, reason} -> {:waiting, reason}
    end
  end

  defp reconcile_envelope(call, arguments) do
    %OperationEnvelope{
      operation: @operation,
      arguments: atomize(arguments),
      actor: restore_actor(call.actor),
      transport: String.to_existing_atom(call.transport),
      call_id: call.call_id,
      mission_id: call.mission_id,
      work_item_id: call.work_item_id,
      attempt_id: call.attempt_id,
      grant: call.grant && String.to_existing_atom(call.grant),
      idempotency_key: call.idempotency_key,
      expected_versions: call.expected_versions,
      gate_id: value(arguments, :gate_id),
      policy: get_in(call.authorization_result || %{}, ["work_policy"]),
      correlation_id: call.correlation_id,
      causation_id: call.causation_id
    }
  end

  @doc false
  def current_preconditions(arguments) do
    with {:ok, _observation, current} <- current_snapshot(arguments) do
      {:ok, current}
    end
  end

  defp scope_references(arguments, envelope) do
    work_item_id = value(arguments, :work_item_id)
    lease_id = value(arguments, :lease_id)
    expected_version = value(arguments, :expected_version)

    with work_item when not is_nil(work_item) <- WorkItems.get(work_item_id),
         %WorkspaceLease{} = lease <- WorkspaceLeases.get(lease_id),
         true <- envelope.work_item_id == work_item_id,
         true <- value(envelope.expected_versions, :work_item) == expected_version,
         true <- lease.work_item.work_item_id == work_item_id do
      {:ok, work_item, lease}
    else
      nil -> {:error, :github_merge_scope_missing}
      false -> {:error, :github_merge_scope_changed}
    end
  end

  defp execution_precondition(arguments, envelope, work_item, lease, observation, current) do
    cond do
      recoverable_merge?(arguments, envelope, work_item, current) ->
        :ok

      not executable_scope?(arguments, envelope, work_item, lease) ->
        {:error, :github_merge_scope_changed}

      current != value(arguments, :external_preconditions) ->
        {:error, :github_merge_preconditions_changed}

      is_nil(Observation.merge_action(observation)) ->
        {:error, :github_merge_not_ready}

      true ->
        :ok
    end
  end

  defp executable_scope?(arguments, envelope, work_item, lease) do
    lease.state == "active" and
      work_item.policy_ref == value(arguments, :policy_version) and
      executable_work?(arguments, envelope, work_item)
  end

  defp executable_work?(arguments, _envelope, %{state: "waiting", phase: "merge_ready"} = work) do
    work.version == value(arguments, :expected_version) and
      waiting_for_gate?(work, value(arguments, :gate_id))
  end

  defp executable_work?(arguments, envelope, %{state: "active", phase: "merging"} = work) do
    work.version == value(arguments, :expected_version) + 2 and
      work.active_operation_call_id == envelope.call_id
  end

  defp executable_work?(_arguments, _envelope, _work_item), do: false

  defp recoverable_merge?(arguments, envelope, work_item, current) do
    pull_request = current["pull_request"]

    pull_request["merged"] == true and
      current["head_sha"] == value(arguments, :expected_head_sha) and
      is_binary(pull_request["merge_commit_sha"]) and
      recoverable_work?(arguments, envelope, work_item, pull_request["merge_commit_sha"])
  end

  defp recoverable_work?(arguments, envelope, work_item, _merge_commit_sha)
       when work_item.state == "active" and work_item.phase == "merging" do
    work_item.version == value(arguments, :expected_version) + 2 and
      work_item.active_operation_call_id == envelope.call_id
  end

  defp recoverable_work?(arguments, _envelope, work_item, _merge_commit_sha)
       when work_item.state == "waiting" and work_item.phase == "merge_ready" do
    work_item.version == value(arguments, :expected_version) and
      waiting_for_gate?(work_item, value(arguments, :gate_id))
  end

  defp recoverable_work?(arguments, _envelope, work_item, _merge_commit_sha)
       when work_item.state == "ready" and work_item.phase == "merge_ready" do
    work_item.version == value(arguments, :expected_version) + 1
  end

  defp recoverable_work?(arguments, _envelope, work_item, merge_commit_sha)
       when work_item.state == "completed" and work_item.phase == "landed" do
    outcome = work_item.outcome || %{}

    value(outcome, :repository) == value(arguments, :repository) and
      value(outcome, :pull_request_number) == value(arguments, :pull_request_number) and
      value(outcome, :head_sha) == value(arguments, :expected_head_sha) and
      value(outcome, :merge_commit_sha) == merge_commit_sha
  end

  defp recoverable_work?(_arguments, _envelope, _work_item, _merge_commit_sha), do: false

  defp current_snapshot(arguments) do
    repository = value(arguments, :repository)
    number = value(arguments, :pull_request_number)

    with {:ok, snapshot} <- Repository.review_snapshot(repository, number),
         {:ok, observation} <- Observation.from_snapshot(repository, number, snapshot) do
      {:ok, observation, Observation.merge_preconditions(observation)}
    end
  end

  defp expected_external(arguments, observation, current) do
    cond do
      current != value(arguments, :external_preconditions) ->
        {:error, {:stale, :github_merge_preconditions_changed, current}}

      is_nil(Observation.merge_action(observation)) ->
        {:error, {:stale, :github_merge_not_ready, current}}

      true ->
        :ok
    end
  end

  defp activate(arguments, envelope) do
    work_item = WorkItems.get(value(arguments, :work_item_id))
    expected_version = value(arguments, :expected_version)

    case work_item do
      %{state: "waiting", phase: "merge_ready", version: ^expected_version} ->
        make_ready(work_item, arguments, envelope, expected_version)

      %{state: "ready", phase: "merge_ready", version: version}
      when version == expected_version + 1 ->
        make_active(work_item, arguments, envelope, version)

      _other ->
        active?(arguments, envelope)
    end
  end

  defp make_ready(work_item, arguments, envelope, expected_version) do
    result =
      WorkOperations.Transition.dispatch(
        work_item.work_item_id,
        %{
          expected_version: expected_version,
          state: "ready",
          phase: "merge_ready",
          evidence: activation_evidence(arguments)
        },
        operation_options(envelope, "ready")
      )

    case result do
      {:ok, _response} -> activate(arguments, envelope)
      {:error, {:stale, _reason}} -> activate(arguments, envelope)
      {:error, reason} -> {:error, reason}
    end
  end

  defp make_active(work_item, arguments, envelope, expected_version) do
    result =
      WorkOperations.Transition.dispatch(
        work_item.work_item_id,
        %{
          expected_version: expected_version,
          state: "active",
          phase: "merging",
          active_operation_call_id: envelope.call_id,
          evidence: activation_evidence(arguments)
        },
        operation_options(envelope, "activate")
      )

    case result do
      {:ok, _response} -> :ok
      {:error, {:stale, _reason}} -> active?(arguments, envelope)
      {:error, reason} -> {:error, reason}
    end
  end

  defp activation_evidence(arguments) do
    %{
      merge_preconditions: value(arguments, :external_preconditions),
      gate_id: value(arguments, :gate_id)
    }
  end

  defp active?(arguments, envelope) do
    expected_call_id = envelope.call_id
    expected_version = value(arguments, :expected_version) + 2

    case WorkItems.get(value(arguments, :work_item_id)) do
      %{state: "ready", phase: "merge_ready", version: version}
      when version == expected_version - 1 ->
        activate(arguments, envelope)

      %{state: "active", phase: "merging", active_operation_call_id: call_id, version: version}
      when call_id == expected_call_id and version == expected_version ->
        :ok

      %{state: "completed", phase: "landed"} ->
        :ok

      work_item ->
        {:error,
         {:stale, :github_merge_activation_changed,
          %{work_item: work_item && WorkItems.render(work_item)}}}
    end
  end

  defp finalize(arguments, envelope, merge_commit_sha, source) do
    with :ok <- activate(arguments, envelope),
         {:ok, work_item} <- complete(arguments, envelope, merge_commit_sha),
         {lease, cleanup} <- release(arguments),
         result <- result(arguments, work_item, lease, cleanup, merge_commit_sha, source) do
      {:ok, result, effects(result)}
    end
  end

  defp complete(arguments, envelope, merge_commit_sha) do
    work_item = WorkItems.get(value(arguments, :work_item_id))
    expected_active_version = value(arguments, :expected_version) + 2

    case work_item do
      %{state: "completed", phase: "landed"} ->
        {:ok, work_item}

      %{state: "active", phase: "merging"} ->
        complete_active(
          work_item,
          arguments,
          envelope,
          merge_commit_sha,
          expected_active_version
        )

      _other ->
        completion_changed(work_item)
    end
  end

  defp complete_active(work_item, arguments, envelope, merge_commit_sha, expected_version) do
    if work_item.version == expected_version and
         work_item.active_operation_call_id == envelope.call_id do
      dispatch_completion(work_item, arguments, envelope, merge_commit_sha, expected_version)
    else
      completion_changed(work_item)
    end
  end

  defp dispatch_completion(work_item, arguments, envelope, merge_commit_sha, expected_version) do
    result =
      WorkOperations.Transition.dispatch(
        work_item.work_item_id,
        %{
          expected_version: expected_version,
          state: "completed",
          phase: "landed",
          outcome: %{
            kind: "github_pull_request_merged",
            repository: value(arguments, :repository),
            pull_request_number: value(arguments, :pull_request_number),
            head_sha: value(arguments, :expected_head_sha),
            merge_commit_sha: merge_commit_sha
          },
          evidence: completion_evidence(arguments, merge_commit_sha)
        },
        operation_options(envelope, "complete")
      )

    case result do
      {:ok, _response} -> {:ok, WorkItems.get(work_item.work_item_id)}
      {:error, {:stale, _reason}} -> completed?(arguments, merge_commit_sha)
      {:error, reason} -> {:error, reason}
    end
  end

  defp completion_changed(work_item) do
    {:error,
     {:stale, :github_merge_completion_changed,
      %{work_item: work_item && WorkItems.render(work_item)}}}
  end

  defp completed?(arguments, merge_commit_sha) do
    case WorkItems.get(value(arguments, :work_item_id)) do
      %{state: "completed", phase: "landed", outcome: outcome} = work_item ->
        if value(outcome, :merge_commit_sha) == merge_commit_sha,
          do: {:ok, work_item},
          else:
            {:error,
             {:stale, :github_merge_commit_changed, %{work_item: WorkItems.render(work_item)}}}

      work_item ->
        {:error,
         {:stale, :github_merge_completion_changed,
          %{work_item: work_item && WorkItems.render(work_item)}}}
    end
  end

  defp release(arguments) do
    git =
      Application.get_env(
        :custode,
        :github_merge_workspace_git,
        Custode.Workspace.Git
      )

    case WorkspaceLeases.release(value(arguments, :lease_id), cleanup: true, git: git) do
      {:ok, lease} ->
        {lease, %{"status" => "released", "error" => nil}}

      {:error, {:cleanup_failed, reason, lease}} ->
        {lease, %{"status" => "failed", "error" => inspect(reason)}}

      {:error, reason} ->
        lease = WorkspaceLeases.get(value(arguments, :lease_id))
        {lease, %{"status" => "failed", "error" => inspect(reason)}}
    end
  end

  defp merge_failure(arguments, reason) do
    case current_preconditions(arguments) do
      {:ok, current} ->
        cond do
          merged_at_expected_head?(arguments, current) ->
            {:waiting, {:github_merge_outcome_uncertain, reason}}

          current != value(arguments, :external_preconditions) ->
            {:error, {:stale, :github_merge_race, current}}

          true ->
            {:error, reason}
        end

      _same_or_unavailable ->
        {:error, reason}
    end
  end

  defp merged_at_expected_head?(arguments, current) do
    pull_request = current["pull_request"]

    pull_request["merged"] == true and
      current["head_sha"] == value(arguments, :expected_head_sha) and
      is_binary(pull_request["merge_commit_sha"])
  end

  defp merge_commit(merged) do
    cond do
      value(merged, :merged) == false -> {:error, :github_pull_request_not_merged}
      is_binary(value(merged, :sha)) -> {:ok, value(merged, :sha)}
      is_binary(value(merged, :merge_commit_sha)) -> {:ok, value(merged, :merge_commit_sha)}
      true -> {:error, :github_merge_commit_missing}
    end
  end

  defp completion_evidence(arguments, merge_commit_sha) do
    external = value(arguments, :external_preconditions)

    %{
      merge_commit: %{
        repository: value(arguments, :repository),
        pull_request_number: value(arguments, :pull_request_number),
        head_sha: value(arguments, :expected_head_sha),
        sha: merge_commit_sha,
        merge_method: pinned_merge_method(arguments)
      },
      acceptance: %{
        gate_id: value(arguments, :gate_id),
        policy_version: value(arguments, :policy_version),
        required_checks: external["required_checks"],
        review_state: external["review_state"],
        approvals: external["approvals"]
      }
    }
  end

  defp result(arguments, work_item, lease, cleanup, merge_commit_sha, source) do
    %{
      work_item: WorkItems.render(work_item),
      pull_request: %{
        repository: value(arguments, :repository),
        number: value(arguments, :pull_request_number),
        head_sha: value(arguments, :expected_head_sha),
        merge_commit_sha: merge_commit_sha,
        merge_method: pinned_merge_method(arguments),
        source: source
      },
      lease: lease && WorkspaceLeases.render(lease),
      cleanup: cleanup
    }
  end

  defp pinned_merge_method(arguments),
    do: arguments |> value(:external_preconditions) |> value(:merge_method)

  # The evidence records the pinned method, so the method sent must be that one
  # (#674). The seam sends it exactly; this refuses to record anything else.
  defp sent_pinned_method(merged, arguments) do
    pinned = pinned_merge_method(arguments)

    case value(merged, :merge_method) do
      ^pinned -> :ok
      sent -> {:error, {:github_merge_method_mismatch, %{pinned: pinned, sent: sent}}}
    end
  end

  defp effects(result) do
    base = [
      %{
        type: "github_pull_request_merged",
        repository: result.pull_request.repository,
        number: result.pull_request.number,
        head_sha: result.pull_request.head_sha,
        merge_commit_sha: result.pull_request.merge_commit_sha,
        merge_method: result.pull_request.merge_method
      },
      %{
        type: "work_item_completed",
        work_item_id: result.work_item.work_item_id,
        phase: result.work_item.phase
      }
    ]

    cleanup_effect =
      if result.cleanup["status"] == "released" do
        %{type: "workspace_lease_released", lease_id: result.lease.lease_id}
      else
        %{
          type: "workspace_cleanup_failed",
          lease_id: result.lease && result.lease.lease_id,
          error: result.cleanup["error"]
        }
      end

    base ++ [cleanup_effect]
  end

  defp waiting_for_gate(work_item, gate_id) do
    if waiting_for_gate?(work_item, gate_id),
      do: :ok,
      else: {:error, {:work_item_not_waiting_for_gate, gate_id}}
  end

  defp waiting_for_gate?(%{state: "waiting", phase: "merge_ready"} = work_item, gate_id) do
    condition = work_item.waiting_condition || %{}
    value(condition, :kind) == "gate" and value(condition, :gate_id) == gate_id
  end

  defp waiting_for_gate?(_work_item, _gate_id), do: false

  defp fetch_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil -> {:error, {:unknown_work_item, work_item_id}}
      work_item -> {:ok, work_item}
    end
  end

  defp fetch_merge_preconditions(action) do
    case value(action, :merge_preconditions) do
      external when is_map(external) -> {:ok, external}
      _missing -> {:error, :merge_preconditions_missing}
    end
  end

  defp fetch_active_lease(work_item_id) do
    case WorkspaceLeases.get_for_work_item(work_item_id) do
      %WorkspaceLease{state: "active"} = lease -> {:ok, lease}
      %WorkspaceLease{state: state} -> {:error, {:workspace_lease_not_active, state}}
      nil -> {:error, :workspace_lease_missing}
    end
  end

  defp fetch_policy_version(work_item) do
    if is_binary(work_item.policy_ref),
      do: {:ok, work_item.policy_ref},
      else: {:error, :merge_policy_version_missing}
  end

  defp operation_options(envelope, stage) do
    [
      actor: %{kind: :system, id: "github-merge"},
      transport: :worker,
      idempotency_key: "github-merge:#{envelope.work_item_id}:#{envelope.call_id}:#{stage}",
      work_policy: envelope.policy,
      correlation_id: envelope.correlation_id,
      causation_id: envelope.call_id
    ]
  end

  defp observed(arguments) do
    %{
      work_item_id: value(arguments, :work_item_id),
      gate_id: value(arguments, :gate_id),
      repository: value(arguments, :repository),
      pull_request_number: value(arguments, :pull_request_number),
      expected_head_sha: value(arguments, :expected_head_sha)
    }
  end

  defp restore_actor(actor) do
    actor = atomize(actor)

    case actor do
      %{kind: kind} when is_binary(kind) -> %{actor | kind: String.to_existing_atom(kind)}
      _other -> actor
    end
  end

  defp atomize(map) when is_map(map) do
    Map.new(map, fn
      {key, item} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), item}
        rescue
          ArgumentError -> {key, item}
        end

      pair ->
        pair
    end)
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
