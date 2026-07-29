defmodule Custode.GitHubIssueVertical do
  @moduledoc """
  The first bounded work-first vertical driven by a configured repository routine.

  It advances only the approved `github_issue_to_merge@1` pilot through
  workspace preparation, reproducible context compilation, one Claude
  implementation Attempt, deterministic verification, draft publication,
  and bounded review repair. Merge remains a separate later slice.
  """

  alias Custode.{
    Attempt,
    Attempts,
    GitHubIssueAttemptDispatcher,
    GitHubIssueContext,
    GitHubIssueVerticalJob,
    PublicationContext,
    RepairContext,
    Routine,
    VerificationContext,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.GitHubReview.Context, as: GitHubReviewContext
  alias Custode.Repair.Disposition
  alias Custode.Workspace.Git

  @max_steps 8

  @doc "Schedule one ID-only coordinator for each eligible intake result."
  def schedule(routine, results, options \\ []) when is_list(results) do
    results
    |> Enum.filter(&eligible?/1)
    |> Enum.reduce_while({:ok, []}, fn result, {:ok, jobs} ->
      work_item_id = result |> value(:work_item) |> value(:work_item_id)

      case enqueue_coordinator(routine.id, work_item_id, options) do
        {:ok, job} -> {:cont, {:ok, [job | jobs]}}
        {:error, reason} -> {:halt, {:error, {:vertical_enqueue_failed, reason}}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, _reason} = error -> error
    end
  end

  @doc "Schedule the ID-only coordinator after a later Attempt advances the WorkItem."
  def schedule_work_item(routine_id, work_item_id, options \\ [])
      when is_binary(routine_id) and is_binary(work_item_id) do
    enqueue_coordinator(routine_id, work_item_id, options)
  end

  @doc "Advance one approved WorkItem until the provider job owns the next step."
  def perform(routine_id, work_item_id, options \\ []) do
    with routine when not is_nil(routine) <- Routine.get(routine_id),
         work_item when not is_nil(work_item) <- WorkItems.get(work_item_id) do
      advance(routine, work_item, Keyword.put(options, :steps_left, @max_steps))
    else
      nil -> {:discard, :vertical_scope_missing}
    end
  end

  defp advance(_routine, _work_item, [{:steps_left, 0} | _options]),
    do: {:error, :github_issue_vertical_step_limit}

  defp advance(routine, %{state: "ready", phase: "eligible"} = work_item, options) do
    with {:ok, repository_id} <- repository_id(work_item),
         repository_path <- Path.expand(routine.working_dir),
         {:ok, base_revision} <- Git.revision(repository_path, "HEAD"),
         {:ok, {_status, bundle}} <-
           GitHubIssueContext.preparation_bundle(
             routine,
             work_item,
             repository_id,
             base_revision,
             options
           ),
         snapshot <-
           preparation_snapshot(
             routine,
             work_item,
             bundle,
             repository_id,
             repository_path,
             base_revision
           ),
         :ok <- execute_claim(work_item, snapshot, options) do
      continue(routine, work_item.work_item_id, options)
    end
  end

  defp advance(routine, %{state: "active", active_attempt_id: attempt_id} = work_item, options) do
    case Attempts.get(attempt_id) do
      %Attempt{} = attempt ->
        advance_active_attempt(routine, work_item, attempt, options)

      nil ->
        {:error, {:unknown_attempt, attempt_id}}
    end
  end

  defp advance(
         routine,
         %{state: "waiting", phase: "compiling_context"} = work_item,
         options
       ) do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, compiled} <- GitHubIssueContext.compile(routine, work_item, lease, options),
         snapshot <- context_wake_snapshot(compiled.bundle),
         :ok <- execute_claim(work_item, snapshot, options) do
      continue(routine, work_item.work_item_id, options)
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(
         routine,
         %{state: "ready", phase: "implementation_ready"} = work_item,
         options
       ) do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, compiled} <- GitHubIssueContext.latest_implementation(routine, work_item),
         snapshot <- implementation_snapshot(routine, work_item, compiled),
         :ok <- execute_claim(work_item, snapshot, options) do
      :ok
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(
         routine,
         %{state: "ready", phase: "verification_ready"} = work_item,
         options
       ) do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, compiled} <- VerificationContext.compile(routine, work_item, lease, options),
         snapshot <- verification_snapshot(routine, work_item, compiled),
         :ok <- execute_claim(work_item, snapshot, options) do
      :ok
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(
         routine,
         %{state: "ready", phase: "repair_ready"} = work_item,
         options
       ) do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, plan} <- RepairContext.plan(routine, work_item, lease, options),
         snapshot <- repair_snapshot(routine, work_item, plan),
         :ok <- execute_claim(work_item, snapshot, options) do
      :ok
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(
         routine,
         %{state: "ready", phase: phase} = work_item,
         options
       )
       when phase in ["feedback_ready", "conflict_ready"] do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, plan} <- GitHubReviewContext.plan(routine, work_item, lease, options),
         snapshot <- review_repair_snapshot(routine, work_item, plan),
         :ok <- execute_claim(work_item, snapshot, options) do
      :ok
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(
         routine,
         %{state: "ready", phase: "publication_ready"} = work_item,
         options
       ) do
    with lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, compiled} <- PublicationContext.compile(routine, work_item, lease, options),
         snapshot <- publication_snapshot(routine, work_item, compiled),
         :ok <- execute_claim(work_item, snapshot, options) do
      :ok
    else
      nil -> {:error, :workspace_lease_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp advance(_routine, _work_item, _options), do: :ok

  defp advance_active_attempt(routine, work_item, attempt, options) do
    if Attempt.terminal?(attempt) do
      with :ok <- execute_claim(work_item, %{}, options) do
        continue(routine, work_item.work_item_id, options)
      end
    else
      :ok
    end
  end

  defp continue(routine, work_item_id, options) do
    next_options = Keyword.update!(options, :steps_left, &(&1 - 1))
    advance(routine, WorkItems.get(work_item_id), next_options)
  end

  defp execute_claim(work_item, snapshot, options) do
    process_options = [
      enqueue: false,
      attempt_dispatcher: GitHubIssueAttemptDispatcher,
      correlation_id: "github-issue-vertical:#{work_item.work_item_id}",
      causation_id: "github-issue-vertical:#{work_item.version}",
      artifact_dir: options[:artifact_dir],
      workspace_root: options[:workspace_root],
      git: options[:git],
      enqueue_fun: options[:provider_enqueue_fun]
    ]

    process_options = Enum.reject(process_options, fn {_key, value} -> is_nil(value) end)

    with {:ok, delivery} <-
           WorkProcess.reconcile(
             work_item.work_item_id,
             work_item.version,
             snapshot,
             process_options
           ) do
      case delivery.status do
        status when status in [:claimed, :enqueued] ->
          WorkProcess.perform(
            delivery.event.event_id,
            work_item.work_item_id,
            work_item.version,
            options[:oban_job_id],
            process_options
          )

        status when status in [:completed, :idle] ->
          :ok
      end
    end
  end

  defp preparation_snapshot(
         routine,
         work_item,
         bundle,
         repository_id,
         repository_path,
         base_revision
       ) do
    %{
      attempt: %{
        attempt_id:
          stable_id("prepare", work_item.work_item_id, work_item.version, base_revision),
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "deterministic",
        provider: "custode",
        profile: "workspace-git",
        recipe_version: "workspace-lease-v1",
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "workspace_preparation",
          legacy_routine_id: routine.id
        },
        dispatch: %{
          work_item_id: work_item.work_item_id,
          repository_id: repository_id,
          repository_path: repository_path,
          base_ref: "HEAD",
          expected_base_revision: base_revision,
          provenance: %{
            legacy_routine_id: routine.id,
            context_bundle_digest: bundle.digest
          }
        }
      }
    }
  end

  defp context_wake_snapshot(bundle) do
    %{
      wake: %{
        kind: "reconciler",
        evidence: %{context_bundle_digest: bundle.digest},
        transition: %{
          state: "ready",
          phase: "implementation_ready",
          evidence: %{
            context_bundle_digest: %{
              context_bundle_id: bundle.context_bundle_id,
              digest: bundle.digest
            }
          }
        }
      }
    }
  end

  defp implementation_snapshot(routine, work_item, compiled) do
    bundle = compiled.bundle
    template = compiled.template
    effort = routine.effort || "default"

    %{
      attempt: %{
        attempt_id: stable_id("claude", work_item.work_item_id, bundle.digest),
        role_binding_id: compiled.binding.binding_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "model",
        provider: "claude",
        profile: "#{routine.model}:#{effort}",
        recipe_version: template.version,
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "github_issue_implementation",
          legacy_routine_id: routine.id,
          capabilities: GitHubIssueContext.capabilities()
        },
        dispatch: %{legacy_routine_id: routine.id}
      }
    }
  end

  defp verification_snapshot(routine, work_item, compiled) do
    producer = compiled.producer_attempt
    recipe = compiled.recipe
    bundle = compiled.bundle

    %{
      attempt: %{
        attempt_id: stable_id("verify", work_item.work_item_id, bundle.digest),
        role_binding_id: producer.role_binding && producer.role_binding.binding_id,
        caused_by_attempt_id: producer.attempt_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "deterministic",
        provider: "custode",
        profile: "verification",
        recipe_version: recipe.version,
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "github_issue_verification",
          legacy_routine_id: routine.id,
          verification_recipe_digest: recipe.digest,
          workspace_revision: compiled.workspace_revision["revision"]
        },
        dispatch: %{legacy_routine_id: routine.id}
      }
    }
  end

  defp repair_snapshot(_routine, _work_item, %{kind: :transition} = plan) do
    %{
      repair: %{
        kind: :transition,
        transition: plan.transition
      }
    }
  end

  defp repair_snapshot(routine, work_item, %{kind: :attempt} = plan) do
    disposition = plan.disposition
    source = plan.source_attempt
    model? = disposition.kind == "semantic_repair"
    effort = routine.effort || "default"

    %{
      repair: %{kind: :attempt},
      attempt: %{
        attempt_id: stable_id("repair", work_item.work_item_id, plan.bundle.digest),
        role_binding_id: source.role_binding && source.role_binding.binding_id,
        caused_by_attempt_id: source.attempt_id,
        context_bundle_id: plan.bundle.context_bundle_id,
        executor_kind: if(model?, do: "model", else: "deterministic"),
        provider: if(model?, do: "claude", else: "custode"),
        profile: if(model?, do: "#{routine.model}:#{effort}", else: disposition.kind),
        recipe_version: plan.policy_snapshot.policy.version,
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "github_issue_repair",
          legacy_routine_id: routine.id,
          repair_disposition: Disposition.render(disposition),
          repair_policy: plan.policy_snapshot,
          failure_artifact_id: plan.failure_artifact.artifact_id,
          workspace_revision: plan.workspace_revision["revision"],
          capabilities: if(model?, do: GitHubIssueContext.capabilities(), else: [])
        },
        dispatch: %{legacy_routine_id: routine.id}
      }
    }
  end

  defp review_repair_snapshot(_routine, _work_item, %{kind: :transition} = plan) do
    %{
      repair: %{
        kind: :transition,
        transition: plan.transition
      }
    }
  end

  defp review_repair_snapshot(routine, work_item, %{kind: :attempt} = plan) do
    disposition = plan.disposition
    source = plan.source_attempt
    evidence = plan.observation_evidence
    model? = disposition.kind == "semantic_repair"
    effort = routine.effort || "default"

    %{
      repair: %{kind: :attempt},
      attempt: %{
        attempt_id: stable_id("review-repair", work_item.work_item_id, plan.bundle.digest),
        role_binding_id: source.role_binding && source.role_binding.binding_id,
        caused_by_attempt_id: source.attempt_id,
        context_bundle_id: plan.bundle.context_bundle_id,
        executor_kind: if(model?, do: "model", else: "deterministic"),
        provider: if(model?, do: "claude", else: "custode"),
        profile: if(model?, do: "#{routine.model}:#{effort}", else: disposition.kind),
        recipe_version: plan.policy_snapshot.policy.version,
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "github_issue_repair",
          repair_origin: "github_review",
          repair_path: disposition.kind,
          active_phase: evidence["action"]["active_phase"],
          legacy_routine_id: routine.id,
          repair_disposition: Disposition.render(disposition),
          repair_policy: plan.policy_snapshot,
          failure_artifact_id: plan.observation_artifact.artifact_id,
          observation_artifact_id: plan.observation_artifact.artifact_id,
          observation_external_identity: plan.observation_artifact.external_identity,
          observation_item_tokens: evidence["item_tokens"],
          observation_head_sha: evidence["head_sha"],
          observation_base_sha: evidence["base_sha"],
          workspace_revision: plan.workspace_revision["revision"],
          capabilities: if(model?, do: GitHubIssueContext.capabilities(), else: [])
        },
        dispatch: %{legacy_routine_id: routine.id}
      }
    }
  end

  defp publication_snapshot(routine, work_item, compiled) do
    bundle = compiled.bundle
    verification = compiled.verification_attempt
    publication = compiled.publication

    %{
      attempt: %{
        attempt_id: stable_id("publish", work_item.work_item_id, bundle.digest),
        role_binding_id: verification.role_binding && verification.role_binding.binding_id,
        caused_by_attempt_id: verification.attempt_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "deterministic",
        provider: "custode",
        profile: "git-github-publication",
        recipe_version: "github_issue_publication_v1",
        expected_work_item_version: work_item.version,
        provenance: %{
          purpose: "github_issue_publication",
          legacy_routine_id: routine.id,
          workspace_lease_id: compiled.lease.lease_id,
          workspace_revision: publication["expected_workspace_revision"],
          expected_head_revision: publication["expected_head_revision"],
          branch: publication["branch"],
          repository: publication["repository"],
          capabilities: %{
            tools: [],
            operations: ["git.publish_branch", "github.open_pr"]
          }
        },
        dispatch: %{legacy_routine_id: routine.id}
      }
    }
  end

  defp enqueue_coordinator(routine_id, work_item_id, options) do
    enqueue = Keyword.get(options, :enqueue_fun, &Oban.insert/1)
    args = %{"routine_id" => routine_id, "work_item_id" => work_item_id}

    args
    |> GitHubIssueVerticalJob.new(
      meta: %{
        "legacy_routine_id" => routine_id,
        "work_item_id" => work_item_id
      }
    )
    |> enqueue.()
  end

  defp repository_id(work_item) do
    case WorkItems.latest_source_snapshot(work_item.work_item_id) do
      %{"repository_id" => repository_id} when is_binary(repository_id) ->
        {:ok, repository_id}

      _missing ->
        {:error, :repository_id_missing}
    end
  end

  defp eligible?(result) do
    work_item = value(result, :work_item)
    value(work_item, :state) == "ready" and value(work_item, :phase) == "eligible"
  end

  defp stable_id(prefix, first, second, third \\ nil) do
    [prefix, first, second, third]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("|")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 32)
    |> then(&"#{prefix}:#{&1}")
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
