defmodule Custode.VerificationAttempts do
  @moduledoc """
  Durable deterministic verification for the GitHub issue vertical.

  Each command is claimed before execution and its evidence is persisted under
  a key derived from command specification and workspace revision. A retry
  reuses completed evidence and never executes an interrupted claim again.
  """

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundles,
    Routine,
    VerificationAttemptJob,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.Verification.{Recipe, Runner}
  alias Custode.Workspace.Git

  @classification_order ~w(cancellation timeout policy_refusal infrastructure_error test_failure)

  @doc "Insert or recover the one physical job for a queued verification Attempt."
  def dispatch(attempt_id, routine_id, options \\ [])
      when is_binary(attempt_id) and is_binary(routine_id) do
    enqueue = Keyword.get(options, :enqueue_fun, &Oban.insert/1)

    with %Attempt{} = attempt <- Attempts.get(attempt_id),
         :ok <- dispatchable(attempt, routine_id),
         {:ok, job} <- attempt |> job_changeset(routine_id) |> enqueue.(),
         :ok <- bind_job(attempt_id, job.id) do
      :ok
    else
      nil -> {:error, {:unknown_attempt, attempt_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Run, persist, and apply one deterministic verification Attempt."
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc false
  def perform(%Oban.Job{} = job, options) when is_list(options) do
    case job.args do
      %{"attempt_id" => attempt_id, "routine_id" => routine_id} ->
        perform_attempt(job, attempt_id, routine_id, options)

      _invalid ->
        {:discard, :invalid_verification_attempt}
    end
  end

  defp perform_attempt(job, attempt_id, routine_id, options) do
    case Attempts.get(attempt_id) do
      nil ->
        {:discard, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt when attempt.state in ~w(succeeded partial blocked failed cancelled) ->
        advance(attempt, job)

      %Attempt{} = attempt ->
        run(attempt, routine_id, job, options)
    end
  end

  defp run(attempt, routine_id, job, options) do
    with {:ok, running} <- ensure_running(attempt, job),
         {:ok, runtime} <- runtime(running, routine_id, options),
         {:ok, results} <- run_commands(running, runtime, options),
         {:ok, finished} <- persist_and_finish(running, runtime, results, options) do
      advance(finished, job)
    else
      {:error, reason} ->
        finish_preflight_failure(attempt, routine_id, reason, job, options)
    end
  end

  defp runtime(attempt, routine_id, options) do
    with :ok <- dispatchable(attempt, routine_id),
         routine when not is_nil(routine) <- Routine.get(routine_id),
         :ok <- active_owner(attempt),
         lease when not is_nil(lease) <-
           WorkspaceLeases.get_for_work_item(attempt.work_item.work_item_id),
         "active" <- lease.state,
         {:ok, _lease} <- heartbeat(lease.lease_id, options),
         :ok <- Git.ownership(lease.repository_path, lease.workspace_path),
         {:ok, context_body} <- ContextBundles.body(attempt.context_bundle),
         {:ok, recipe} <- verification_recipe(context_body),
         {:ok, revision} <- Git.workspace_revision(lease.workspace_path),
         :ok <- expected_revision(context_body, revision) do
      {:ok,
       %{
         routine: routine,
         lease: lease,
         context_body: context_body,
         recipe: recipe,
         workspace_revision: revision
       }}
    else
      nil -> {:error, :verification_scope_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp heartbeat(lease_id, options) do
    heartbeat_options =
      [git: options[:git]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    WorkspaceLeases.heartbeat(lease_id, heartbeat_options)
  end

  defp verification_recipe(context_body) do
    context_body
    |> get_in(["recipe", "verification"])
    |> case do
      nil -> {:error, :verification_recipe_missing}
      recipe -> Recipe.new(recipe)
    end
  end

  defp expected_revision(context_body, observed) do
    expected = get_in(context_body, ["workspace_revision", "revision"])

    if expected == observed["revision"] do
      :ok
    else
      {:error,
       {:workspace_revision_changed, %{expected: expected, observed: observed["revision"]}}}
    end
  end

  defp run_commands(attempt, runtime, options) do
    Enum.reduce_while(runtime.recipe.commands, {:ok, []}, fn spec, {:ok, results} ->
      case run_command_step(attempt, runtime, spec, options) do
        {:ok, result, :unchanged} ->
          {:cont, {:ok, [result | results]}}

        {:ok, result, {:changed, after_revision}} ->
          changed =
            workspace_changed_result(
              spec,
              runtime.workspace_revision["revision"],
              after_revision["revision"]
            )

          {:halt, {:ok, [changed, result | results]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _reason} = error -> error
    end
  end

  defp run_command_step(attempt, runtime, spec, options) do
    with {:ok, current} <- Git.workspace_revision(runtime.lease.workspace_path),
         :ok <- same_revision(runtime.workspace_revision, current),
         {:ok, result} <- command_result(attempt, runtime, spec, options),
         :ok <- after_command(result, options),
         {:ok, after_revision} <- Git.workspace_revision(runtime.lease.workspace_path) do
      change =
        if after_revision["revision"] == runtime.workspace_revision["revision"],
          do: :unchanged,
          else: {:changed, after_revision}

      {:ok, result, change}
    end
  end

  defp same_revision(%{"revision" => revision}, %{"revision" => revision}), do: :ok

  defp same_revision(expected, observed) do
    {:error,
     {:workspace_revision_changed,
      %{expected: expected["revision"], observed: observed["revision"]}}}
  end

  defp command_result(attempt, runtime, spec, options) do
    ids = command_artifact_ids(attempt, runtime, spec)

    case Artifacts.get(ids.result) do
      %Artifact{} = artifact ->
        reuse_result(artifact, runtime, spec)

      nil ->
        claim_and_run(attempt, runtime, spec, ids, options)
    end
  end

  defp claim_and_run(attempt, runtime, spec, ids, options) do
    case claim_command(attempt, runtime, spec, ids.claim, options) do
      {:ok, :created} ->
        runner = Keyword.get(options, :runner, Runner)

        with {:ok, result} <-
               run_command(
                 runner,
                 spec,
                 runtime.lease.workspace_path,
                 options[:runner_options] || []
               ),
             body <-
               result
               |> Map.put("recipe_digest", runtime.recipe.digest)
               |> Map.put("workspace_revision", runtime.workspace_revision["revision"])
               |> Map.put("claim_artifact_id", ids.claim),
             {:ok, artifact} <-
               put_result(attempt, runtime, spec, ids.result, body, options) do
          {:ok,
           body
           |> Runner.metadata()
           |> Map.put("artifact_id", artifact.artifact_id)
           |> Map.put("reused", false)}
        end

      {:ok, :existing} ->
        interrupted = interrupted_result(spec, runtime, ids.claim)

        with {:ok, artifact} <-
               put_result(attempt, runtime, spec, ids.result, interrupted, options) do
          {:ok,
           interrupted
           |> Runner.metadata()
           |> Map.put("artifact_id", artifact.artifact_id)
           |> Map.put("reused", false)}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp claim_command(attempt, runtime, spec, artifact_id, options) do
    case Artifacts.get(artifact_id) do
      %Artifact{} ->
        {:ok, :existing}

      nil ->
        body =
          Jason.encode!(%{
            "command_spec_digest" => spec.digest,
            "recipe_digest" => runtime.recipe.digest,
            "workspace_revision" => runtime.workspace_revision["revision"]
          })

        case Artifacts.put(
               attempt.work_item.work_item_id,
               body,
               artifact_attrs(
                 attempt,
                 runtime,
                 spec,
                 artifact_id,
                 "verification_command_claim"
               ),
               artifact_options(options)
             ) do
          {:ok, _artifact} -> {:ok, :created}
          {:error, {:artifact_write, :eexist}} -> orphaned(artifact_id)
          {:error, _reason} = error -> error
        end
    end
  end

  defp put_result(attempt, runtime, spec, artifact_id, body, options) do
    encoded = Jason.encode!(body)

    case Artifacts.get(artifact_id) do
      %Artifact{} = artifact ->
        existing_result(artifact, runtime, spec)

      nil ->
        case Artifacts.put(
               attempt.work_item.work_item_id,
               encoded,
               artifact_attrs(
                 attempt,
                 runtime,
                 spec,
                 artifact_id,
                 "verification_command_result"
               ),
               artifact_options(options)
             ) do
          {:ok, artifact} -> {:ok, artifact}
          {:error, {:artifact_write, :eexist}} -> orphaned(artifact_id)
          {:error, _reason} = error -> error
        end
    end
  end

  defp reuse_result(artifact, runtime, spec) do
    with {:ok, body} <- read_json_artifact(artifact),
         :ok <- result_matches(body, runtime, spec) do
      {:ok,
       body
       |> Runner.metadata()
       |> Map.put("artifact_id", artifact.artifact_id)
       |> Map.put("reused", true)}
    end
  end

  defp existing_result(artifact, runtime, spec) do
    with {:ok, body} <- read_json_artifact(artifact),
         :ok <- result_matches(body, runtime, spec) do
      {:ok, artifact}
    end
  end

  defp result_matches(body, runtime, spec) do
    if body["command_spec_digest"] == spec.digest and
         body["recipe_digest"] == runtime.recipe.digest and
         body["workspace_revision"] == runtime.workspace_revision["revision"] do
      :ok
    else
      {:error, {:verification_evidence_conflict, spec.name}}
    end
  end

  defp interrupted_result(spec, runtime, claim_artifact_id) do
    %{
      "name" => spec.name,
      "category" => spec.category,
      "status" => "infrastructure_error",
      "reason" => "execution_interrupted_after_durable_claim",
      "exit_code" => nil,
      "duration_ms" => 0,
      "command_spec_digest" => spec.digest,
      "runner_version" => Runner.runner_version(),
      "stdout_bytes" => 0,
      "stderr_bytes" => 0,
      "stdout_tail" => "",
      "stderr_tail" => "",
      "stdout_tail_encoding" => "utf-8",
      "stderr_tail_encoding" => "utf-8",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "output_limit_bytes" => spec.output_limit_bytes,
      "recipe_digest" => runtime.recipe.digest,
      "workspace_revision" => runtime.workspace_revision["revision"],
      "claim_artifact_id" => claim_artifact_id,
      "output" => %{}
    }
  end

  defp workspace_changed_result(spec, expected, observed) do
    %{
      "name" => "#{spec.name}_workspace_revision",
      "category" => spec.category,
      "status" => "policy_refusal",
      "reason" => "workspace_changed_during_verification",
      "exit_code" => nil,
      "duration_ms" => 0,
      "command_spec_digest" => spec.digest,
      "runner_version" => Runner.runner_version(),
      "stdout_bytes" => 0,
      "stderr_bytes" => 0,
      "stdout_tail" => "",
      "stderr_tail" => "",
      "stdout_tail_encoding" => "utf-8",
      "stderr_tail_encoding" => "utf-8",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "output_limit_bytes" => spec.output_limit_bytes,
      "expected_workspace_revision" => expected,
      "observed_workspace_revision" => observed,
      "artifact_id" => nil,
      "reused" => false
    }
  end

  defp persist_and_finish(attempt, runtime, results, options) do
    stable_results = Enum.map(results, &Map.delete(&1, "reused"))
    classification = classification(stable_results)
    evidence = evidence(attempt, runtime, stable_results)

    with {:ok, manifest} <-
           put_manifest(attempt, runtime, stable_results, classification, options),
         {:ok, failure} <-
           put_failure(attempt, runtime, stable_results, classification, options),
         finish_attrs <-
           finish_attrs(
             runtime,
             stable_results,
             classification,
             evidence,
             manifest,
             failure
           ) do
      Attempts.finish(attempt.attempt_id, finish_attrs)
    end
  end

  defp put_manifest(attempt, runtime, results, classification, options) do
    body =
      Jason.encode!(%{
        "attempt_id" => attempt.attempt_id,
        "classification" => classification,
        "recipe" => Recipe.render(runtime.recipe),
        "workspace_revision" => runtime.workspace_revision,
        "results" => results
      })

    put_once(
      attempt,
      "verification-manifest:#{attempt.attempt_id}",
      body,
      "verification_manifest",
      %{
        recipe_digest: runtime.recipe.digest,
        workspace_revision: runtime.workspace_revision["revision"]
      },
      options
    )
  end

  defp put_failure(_attempt, _runtime, _results, "pass", _options), do: {:ok, nil}

  defp put_failure(attempt, runtime, results, classification, options) do
    focused =
      results
      |> Enum.reject(&(&1["status"] == "pass"))
      |> Enum.map(fn result ->
        Map.take(result, [
          "name",
          "category",
          "status",
          "reason",
          "exit_code",
          "duration_ms",
          "command_spec_digest",
          "artifact_id",
          "stdout_tail",
          "stderr_tail",
          "stdout_tail_encoding",
          "stderr_tail_encoding",
          "stdout_truncated",
          "stderr_truncated"
        ])
      end)

    body =
      Jason.encode!(%{
        "attempt_id" => attempt.attempt_id,
        "classification" => classification,
        "recipe_digest" => runtime.recipe.digest,
        "workspace_revision" => runtime.workspace_revision["revision"],
        "failures" => focused
      })

    put_once(
      attempt,
      "verification-failure:#{attempt.attempt_id}",
      body,
      "verification_failure",
      %{
        recipe_digest: runtime.recipe.digest,
        workspace_revision: runtime.workspace_revision["revision"]
      },
      options
    )
  end

  defp put_once(attempt, artifact_id, body, kind, provenance, options) do
    case Artifacts.get(artifact_id) do
      %Artifact{} = artifact ->
        if artifact.digest == Artifacts.digest(body),
          do: {:ok, artifact},
          else: {:error, {:artifact_conflict, artifact_id}}

      nil ->
        Artifacts.put(
          attempt.work_item.work_item_id,
          body,
          %{
            artifact_id: artifact_id,
            producer_attempt_id: attempt.attempt_id,
            kind: kind,
            media_type: "application/json",
            provenance: provenance,
            retention: %{until: "work_item_terminal"}
          },
          artifact_options(options)
        )
    end
  end

  defp finish_attrs(runtime, results, classification, evidence, manifest, failure) do
    artifacts =
      evidence
      |> Map.put(:manifest_artifact_id, manifest.artifact_id)
      |> maybe_put(:failure_artifact_id, failure && failure.artifact_id)

    %{
      state: attempt_state(classification),
      usage: %{
        cost_usd: 0,
        duration_ms: Enum.sum(Enum.map(results, &(&1["duration_ms"] || 0))),
        commands: length(results)
      },
      error_class: if(classification == "pass", do: nil, else: classification),
      error_details:
        if(classification == "pass",
          do: nil,
          else: %{failed_commands: failed_command_names(results)}
        ),
      outcome: %{
        kind: "deterministic_verification",
        classification: classification,
        recipe: %{
          name: runtime.recipe.name,
          version: runtime.recipe.version,
          digest: runtime.recipe.digest
        },
        workspace_revision: runtime.workspace_revision,
        results: results,
        artifacts: artifacts,
        proposal: proposal(classification, artifacts)
      }
    }
  end

  defp evidence(attempt, runtime, results) do
    %{
      context_bundle_id: attempt.context_bundle.context_bundle_id,
      context_digest: attempt.context_digest,
      workspace_lease_id: runtime.lease.lease_id,
      workspace_revision: runtime.workspace_revision["revision"],
      recipe_digest: runtime.recipe.digest,
      command_result_artifact_ids:
        results |> Enum.map(& &1["artifact_id"]) |> Enum.reject(&is_nil/1)
    }
  end

  defp proposal("pass", evidence) do
    %{
      state: "ready",
      phase: "publication_ready",
      evidence: %{verification: evidence}
    }
  end

  defp proposal(_classification, evidence) do
    %{
      state: "ready",
      phase: "repair_ready",
      evidence: %{verification_failure: evidence}
    }
  end

  defp classification(results) do
    statuses = MapSet.new(Enum.map(results, & &1["status"]))
    Enum.find(@classification_order, "pass", &MapSet.member?(statuses, &1))
  end

  defp attempt_state("pass"), do: "succeeded"
  defp attempt_state("cancellation"), do: "cancelled"
  defp attempt_state(_classification), do: "failed"

  defp failed_command_names(results) do
    results
    |> Enum.reject(&(&1["status"] == "pass"))
    |> Enum.map(& &1["name"])
  end

  defp finish_preflight_failure(attempt, routine_id, reason, job, options) do
    case Attempts.get(attempt.attempt_id) do
      %Attempt{} = current when current.state in ~w(queued running) ->
        with {:ok, running} <- ensure_running(current, job),
             {:ok, runtime} <- fallback_runtime(running, routine_id),
             result <- preflight_result(reason),
             {:ok, finished} <- persist_and_finish(running, runtime, [result], options) do
          advance(finished, job)
        end

      %Attempt{} = terminal ->
        advance(terminal, job)

      nil ->
        {:discard, {:unknown_attempt, attempt.attempt_id}}
    end
  end

  defp fallback_runtime(attempt, routine_id) do
    with {:ok, context_body} <- ContextBundles.body(attempt.context_bundle),
         {:ok, recipe} <- verification_recipe(context_body) do
      lease = WorkspaceLeases.get_for_work_item(attempt.work_item.work_item_id)

      revision =
        get_in(context_body, ["workspace_revision"])
        |> Map.take(["revision", "head_revision", "diff_digest", "changed_files"])

      {:ok,
       %{
         routine: Routine.get(routine_id),
         lease: lease || %{lease_id: nil},
         context_body: context_body,
         recipe: recipe,
         workspace_revision: revision
       }}
    end
  end

  defp preflight_result(reason) do
    status = if policy_preflight?(reason), do: "policy_refusal", else: "infrastructure_error"

    %{
      "name" => "verification_preflight",
      "category" => "repository",
      "status" => status,
      "reason" => inspect(reason),
      "exit_code" => nil,
      "duration_ms" => 0,
      "command_spec_digest" => nil,
      "runner_version" => Runner.runner_version(),
      "stdout_bytes" => 0,
      "stderr_bytes" => 0,
      "stdout_tail" => "",
      "stderr_tail" => "",
      "stdout_tail_encoding" => "utf-8",
      "stderr_tail_encoding" => "utf-8",
      "stdout_truncated" => false,
      "stderr_truncated" => false,
      "output_limit_bytes" => 0,
      "artifact_id" => nil,
      "reused" => false
    }
  end

  defp policy_preflight?({:workspace_revision_changed, _details}), do: true
  defp policy_preflight?({:workspace_lease_not_active, _state}), do: true
  defp policy_preflight?({:command_spec_digest_mismatch, _name}), do: true
  defp policy_preflight?({:verification_recipe_digest_mismatch, _name}), do: true
  defp policy_preflight?(:attempt_not_active_owner), do: true
  defp policy_preflight?(:workspace_ownership_unproven), do: true
  defp policy_preflight?(:verification_recipe_missing), do: true
  defp policy_preflight?(:verification_recipe_reference_required), do: true
  defp policy_preflight?(:unsupported_verification_recipe), do: true
  defp policy_preflight?(_reason), do: false

  defp advance(attempt, job) do
    work_item = WorkItems.get(attempt.work_item.work_item_id)
    proposal = get_in(attempt.outcome || %{}, ["proposal"])

    cond do
      work_item.state == "active" and work_item.active_attempt_id == attempt.attempt_id ->
        with {:ok, delivery} <-
               WorkProcess.reconcile(
                 work_item.work_item_id,
                 work_item.version,
                 %{},
                 enqueue: false,
                 correlation_id: "verification-attempt:#{attempt.attempt_id}",
                 causation_id: "oban:#{job.id}"
               ) do
          WorkProcess.perform(
            delivery.event.event_id,
            work_item.work_item_id,
            work_item.version,
            job.id
          )
        end

      transition_applied?(work_item, proposal) ->
        :ok

      true ->
        {:error,
         {:attempt_result_not_applied,
          %{attempt_id: attempt.attempt_id, state: work_item.state, phase: work_item.phase}}}
    end
  end

  defp transition_applied?(work_item, proposal) when is_map(proposal) do
    work_item.state == value(proposal, :state) and work_item.phase == value(proposal, :phase)
  end

  defp transition_applied?(_work_item, _proposal), do: false

  defp job_changeset(attempt, routine_id) do
    args = %{"attempt_id" => attempt.attempt_id, "routine_id" => routine_id}

    VerificationAttemptJob.new(args,
      meta: %{
        "legacy_routine_id" => routine_id,
        "attempt_id" => attempt.attempt_id,
        "work_item_id" => attempt.work_item.work_item_id,
        "mission_id" => attempt.work_item.mission.mission_id
      }
    )
  end

  defp bind_job(attempt_id, job_id) do
    case Attempts.start(attempt_id, %{oban_job_id: job_id}) do
      {:ok, _attempt} -> :ok
      {:error, {:attempt_terminal, _state}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_running(%Attempt{state: state} = attempt, job) when state in ~w(queued running),
    do: Attempts.start(attempt.attempt_id, %{oban_job_id: job.id})

  defp dispatchable(%Attempt{} = attempt, routine_id) do
    expected_routine = get_in(attempt.provenance, ["legacy_routine_id"])

    cond do
      attempt.executor_kind != "deterministic" ->
        {:error, :deterministic_attempt_required}

      attempt.provider != "custode" ->
        {:error, :custode_verifier_required}

      get_in(attempt.provenance, ["purpose"]) != "github_issue_verification" ->
        {:error, :verification_attempt_required}

      expected_routine != routine_id ->
        {:error, :legacy_routine_mismatch}

      true ->
        :ok
    end
  end

  defp active_owner(attempt) do
    work_item = attempt.work_item

    valid? =
      work_item.state == "active" and
        work_item.phase == "verifying" and
        work_item.active_attempt_id == attempt.attempt_id and
        work_item.version == attempt.expected_work_item_version + 1

    if valid?, do: :ok, else: {:error, :attempt_not_active_owner}
  end

  defp command_artifact_ids(attempt, runtime, spec) do
    identity =
      [
        attempt.work_item.work_item_id,
        runtime.recipe.digest,
        spec.digest,
        runtime.workspace_revision["revision"]
      ]
      |> Enum.join("|")
      |> digest()

    %{
      claim: "verification-claim:#{identity}",
      result: "verification-result:#{identity}"
    }
  end

  defp artifact_attrs(attempt, runtime, spec, artifact_id, kind) do
    %{
      artifact_id: artifact_id,
      producer_attempt_id: attempt.attempt_id,
      kind: kind,
      media_type: "application/json",
      provenance: %{
        recipe_digest: runtime.recipe.digest,
        command_name: spec.name,
        command_spec_digest: spec.digest,
        workspace_revision: runtime.workspace_revision["revision"],
        runner_version: Runner.runner_version()
      },
      retention: %{until: "work_item_terminal"}
    }
  end

  defp artifact_options(options) do
    [artifact_dir: options[:artifact_dir]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp read_json_artifact(artifact) do
    with {:ok, encoded} <- File.read(artifact.location),
         true <- Artifacts.digest(encoded) == artifact.digest,
         {:ok, body} <- Jason.decode(encoded) do
      {:ok, body}
    else
      false -> {:error, :artifact_digest_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp after_command(result, options) do
    case Keyword.get(options, :after_command, fn _result -> :ok end).(result) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp run_command(runner, spec, path, options) when is_function(runner, 3),
    do: runner.(spec, path, options)

  defp run_command(runner, spec, path, options), do: runner.run(spec, path, options)

  defp orphaned(artifact_id), do: {:error, {:verification_artifact_orphaned, artifact_id}}

  defp digest(body) do
    :sha256
    |> :crypto.hash(body)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 40)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
