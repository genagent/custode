defmodule Custode.ModelAttempts do
  @moduledoc """
  Provider-neutral orchestration for model implementation and focused semantic
  repair Attempts in the first repository vertical.

  Durable Attempt and Artifact records own the execution. The Oban job carries
  only stable IDs, and a provider-result checkpoint prevents a crash after a
  paid call from causing another call. Provider launch and response shapes stay
  behind an Executor adapter; this module consumes only the neutral contract.
  """

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ClaudeAttemptJob,
    CodexAttemptJob,
    ContextBundles,
    Executor,
    GitHubIssueVertical,
    Routine,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.Executor.{Failure, Request, Result}
  alias Custode.Executors.{Claude, Codex}
  alias Custode.Repair.Disposition
  alias Custode.Workspace.Git

  @doc "Insert or recover the one physical job for a queued logical Attempt."
  def dispatch(attempt_id, routine_id, options \\ [])
      when is_binary(attempt_id) and is_binary(routine_id) do
    enqueue = Keyword.get(options, :enqueue_fun, &Oban.insert/1)

    with %Attempt{} = attempt <- Attempts.get(attempt_id),
         :ok <- dispatchable(attempt, routine_id, options),
         {:ok, job} <-
           attempt
           |> job_changeset(routine_id)
           |> enqueue.(),
         :ok <- bind_job(attempt_id, job.id) do
      :ok
    else
      nil -> {:error, {:unknown_attempt, attempt_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc "Run, checkpoint, persist, and advance one implementation Attempt."
  def perform(
        %Oban.Job{
          args: %{"attempt_id" => attempt_id, "routine_id" => routine_id}
        } = job
      ) do
    perform(job, attempt_id, routine_id, [])
  end

  def perform(%Oban.Job{}), do: {:discard, :invalid_model_attempt}

  @doc false
  def perform(
        %Oban.Job{} = job,
        options
      )
      when is_list(options) do
    case job.args do
      %{"attempt_id" => attempt_id, "routine_id" => routine_id} ->
        perform(job, attempt_id, routine_id, options)

      _invalid ->
        {:discard, :invalid_model_attempt}
    end
  end

  defp perform(job, attempt_id, routine_id, options) do
    case Attempts.get(attempt_id) do
      nil ->
        {:discard, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt ->
        case provider_matches?(attempt, options) do
          :ok ->
            perform_attempt(attempt, routine_id, job, options)

          {:error, reason} ->
            {:discard, reason}
        end
    end
  end

  defp perform_attempt(attempt, routine_id, job, options) do
    cond do
      Attempt.terminal?(attempt) ->
        advance(attempt, job, options)

      checkpoint = checkpoint(attempt) ->
        recover_checkpoint(attempt, checkpoint, job, options)

      true ->
        run(attempt, routine_id, job, options)
    end
  end

  defp run(attempt, routine_id, job, options) do
    with {:ok, running} <- ensure_running(attempt, job),
         {:ok, runtime} <- runtime(running, routine_id, job, options),
         {:ok, executor_result} <-
           Executor.execute(
             executor(running),
             runtime.request,
             executor_options(running, job, options)
           ),
         {:ok, changed_files} <- Git.changed_files(runtime.lease.workspace_path),
         {:ok, diff} <- Git.diff(runtime.lease.workspace_path) do
      classification = classify(executor_result, changed_files, job)

      if classification["retry"] do
        retry_verdict(executor_result)
      else
        persist_and_finish(
          running,
          runtime,
          executor_result,
          classification,
          changed_files,
          diff,
          job,
          options
        )
      end
    else
      {:error, reason} ->
        finish_preflight_failure(attempt, routine_id, reason, job, options)
    end
  end

  defp runtime(attempt, routine_id, job, options) do
    with :ok <- dispatchable(attempt, routine_id, options),
         routine when not is_nil(routine) <- Routine.get(routine_id),
         work_item = attempt.work_item,
         :ok <- active_owner(attempt, work_item),
         lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, _lease} <- heartbeat(lease.lease_id, options),
         {:ok, context_body} <- ContextBundles.body(attempt.context_bundle),
         {:ok, request} <- executor_request(attempt, routine, lease, context_body, job),
         {:ok, _heartbeat} <-
           Executor.heartbeat(
             executor(attempt),
             request,
             executor_heartbeat_options(options)
           ) do
      {:ok,
       %{
         routine: routine,
         work_item: work_item,
         lease: lease,
         context_body: context_body,
         request: request
       }}
    else
      nil -> {:error, :runtime_scope_missing}
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

  defp executor_options(attempt, job, options) do
    query_fun =
      options[:query_fun] ||
        Application.get_env(:custode, query_fun_key(attempt), nil)

    [
      job: job,
      query_fun: query_fun,
      classifier: options[:classifier],
      output_schema_dir: options[:output_schema_dir]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp executor_heartbeat_options(options) do
    [heartbeat_fun: options[:executor_heartbeat_fun]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp persist_and_finish(
         attempt,
         runtime,
         executor_result,
         classification,
         changed_files,
         diff,
         job,
         options
       ) do
    ids = artifact_ids(attempt)

    checkpoint_body = %{
      "attempt_id" => attempt.attempt_id,
      "context_digest" => attempt.context_digest,
      "workspace_lease_id" => runtime.lease.lease_id,
      "executor" => normalize(executor_result.executor),
      "provider" => normalize(executor_result.evidence),
      "transcript_refs" => normalize(executor_result.transcript_refs),
      "executor_artifacts" => normalize(executor_result.artifacts),
      "cancellation" => normalize(executor_result.cancellation),
      "executor_failure" => normalize_failure(executor_result.failure),
      "classification" => classification,
      "usage" => executor_result.usage,
      "provider_continuation" => executor_result.continuation,
      "changed_files" => changed_files,
      "diff" => diff,
      "artifact_ids" => ids
    }

    with {:ok, checkpoint} <-
           put_once(
             attempt,
             ids.checkpoint,
             Jason.encode!(checkpoint_body),
             "provider_result",
             "application/json",
             options
           ),
         :ok <- after_checkpoint(checkpoint, options) do
      recover_checkpoint(attempt, checkpoint, job, options)
    end
  end

  defp recover_checkpoint(attempt, checkpoint, job, options) do
    with {:ok, body} <- read_json_artifact(checkpoint),
         :ok <- checkpoint_matches(attempt, body),
         {:ok, changed_files_artifact} <-
           put_once(
             attempt,
             body["artifact_ids"]["changed_files"],
             Jason.encode!(body["changed_files"]),
             "changed_files",
             "application/json",
             options
           ),
         {:ok, diff_artifact} <-
           put_once(
             attempt,
             body["artifact_ids"]["diff"],
             body["diff"],
             "implementation_diff",
             "text/x-diff",
             Keyword.put(options, :extension, ".diff")
           ),
         finish_attrs <-
           finish_attrs(
             attempt,
             body,
             checkpoint,
             changed_files_artifact,
             diff_artifact
           ),
         {:ok, finished} <- Attempts.finish(attempt.attempt_id, finish_attrs) do
      advance(finished, job, options)
    end
  end

  defp finish_preflight_failure(attempt, routine_id, reason, job, options) do
    case Attempts.get(attempt.attempt_id) do
      %Attempt{} = current when current.state in ~w(queued running) ->
        with {:ok, running} <- ensure_running(current, job),
             runtime <- preflight_runtime(running, routine_id),
             {:ok, changed_files, diff} <- available_workspace_evidence(runtime),
             classification <- blocked_classification(reason),
             executor_result <- preflight_executor_result(running, reason) do
          persist_and_finish(
            running,
            runtime,
            executor_result,
            classification,
            changed_files,
            diff,
            job,
            options
          )
        end

      %Attempt{} = terminal ->
        advance(terminal, job, options)

      nil ->
        {:discard, {:unknown_attempt, attempt.attempt_id}}
    end
  end

  defp preflight_runtime(attempt, routine_id) do
    lease = WorkspaceLeases.get_for_work_item(attempt.work_item.work_item_id)

    %{
      routine: Routine.get(routine_id),
      work_item: attempt.work_item,
      lease:
        lease ||
          %{
            lease_id: nil,
            workspace_path: nil
          }
    }
  end

  defp available_workspace_evidence(%{lease: %{workspace_path: path}})
       when is_binary(path) do
    with {:ok, changed_files} <- Git.changed_files(path),
         {:ok, diff} <- Git.diff(path) do
      {:ok, changed_files, diff}
    else
      _unavailable -> {:ok, [], ""}
    end
  end

  defp available_workspace_evidence(_runtime), do: {:ok, [], ""}

  defp finish_attrs(attempt, body, checkpoint, changed_files_artifact, diff_artifact) do
    classification = body["classification"]

    evidence = %{
      context_bundle_id: attempt.context_bundle.context_bundle_id,
      context_digest: attempt.context_digest,
      provider_checkpoint_artifact_id: checkpoint.artifact_id,
      changed_files_artifact_id: changed_files_artifact.artifact_id,
      diff_artifact_id: diff_artifact.artifact_id,
      diff_digest: diff_artifact.digest,
      workspace_lease_id: body["workspace_lease_id"]
    }

    %{
      state: classification["attempt_state"],
      usage: body["usage"],
      provider_continuation: body["provider_continuation"],
      error_class: classification["error_class"],
      error_details: classification["error_details"],
      outcome: %{
        kind: attempt_kind(attempt),
        classification: classification["category"],
        summary: classification["summary"],
        structured_output: get_in(body, ["provider", "structured_output"]),
        artifacts: evidence,
        proposal: proposal(attempt, classification, evidence)
      }
    }
  end

  defp proposal(attempt, %{"category" => "success"}, evidence) do
    %{
      state: "ready",
      phase: "verification_ready",
      evidence: success_evidence(attempt, evidence)
    }
  end

  defp proposal(
         attempt,
         %{"category" => "retryable_infrastructure"} = classification,
         evidence
       ) do
    if repair_attempt?(attempt) do
      repair_ready_proposal(attempt, evidence)
    else
      implementation_retry_proposal(classification, evidence)
    end
  end

  defp proposal(
         attempt,
         %{"category" => "semantic_follow_up"} = classification,
         evidence
       ) do
    if repair_attempt?(attempt) do
      repair_ready_proposal(attempt, evidence)
    else
      blocked_proposal(attempt, classification, evidence)
    end
  end

  defp proposal(attempt, %{"category" => "human_question"} = classification, evidence) do
    disposition =
      if repair_attempt?(attempt),
        do: provider_disposition(attempt, classification, evidence, "human_ask"),
        else: nil

    %{
      state: "waiting",
      phase: active_phase(attempt),
      waiting_condition: %{
        kind: "external_event",
        name: "operator_answer",
        question: classification["question"],
        repair_disposition: disposition
      },
      evidence: failure_evidence(attempt, evidence, disposition)
    }
  end

  defp proposal(attempt, classification, evidence) do
    blocked_proposal(attempt, classification, evidence)
  end

  defp blocked_proposal(attempt, classification, evidence) do
    disposition =
      if repair_attempt?(attempt),
        do: provider_disposition(attempt, classification, evidence, "terminal_block"),
        else: nil

    %{
      state: "blocked",
      phase: active_phase(attempt),
      blocked_reason: %{
        code: if(disposition, do: "repair_terminal_block", else: classification["category"]),
        reason: classification["summary"],
        repair_disposition: disposition
      },
      evidence: failure_evidence(attempt, evidence, disposition)
    }
  end

  defp repair_ready_proposal(attempt, evidence) do
    %{
      state: "ready",
      phase: "repair_ready",
      evidence: %{repair_failure: repair_evidence(attempt, evidence)}
    }
  end

  defp implementation_retry_proposal(classification, evidence) do
    %{
      state: "waiting",
      phase: "implementing",
      waiting_condition: %{
        kind: "reconciler",
        name: "provider_retry",
        error: classification["error_details"]
      },
      evidence: %{implementation_failure: evidence}
    }
  end

  defp advance(attempt, job, options) do
    work_item = WorkItems.get(attempt.work_item.work_item_id)
    proposal = get_in(attempt.outcome || %{}, ["proposal"])

    with :ok <- apply_proposal(attempt, work_item, proposal, job) do
      schedule_next(attempt, job, options)
    end
  end

  defp apply_proposal(attempt, work_item, proposal, job) do
    cond do
      work_item.state == "active" and work_item.active_attempt_id == attempt.attempt_id ->
        with {:ok, delivery} <-
               WorkProcess.reconcile(
                 work_item.work_item_id,
                 work_item.version,
                 %{},
                 enqueue: false,
                 correlation_id: "#{attempt.provider}-attempt:#{attempt.attempt_id}",
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

  defp schedule_next(attempt, job, options) do
    work_item = WorkItems.get(attempt.work_item.work_item_id)

    if work_item.state == "ready" and
         work_item.phase in ~w(verification_ready repair_ready) do
      schedule_options =
        [enqueue_fun: options[:vertical_enqueue_fun]]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case GitHubIssueVertical.schedule_work_item(
             job.args["routine_id"],
             work_item.work_item_id,
             schedule_options
           ) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, {:verification_enqueue_failed, reason}}
      end
    else
      :ok
    end
  end

  defp transition_applied?(work_item, proposal) when is_map(proposal) do
    work_item.state == value(proposal, :state) and work_item.phase == value(proposal, :phase)
  end

  defp transition_applied?(_work_item, _proposal), do: false

  defp executor_request(attempt, routine, lease, context_body, job) do
    configured = Routine.tick_args(routine)["start"]["args"]
    capabilities = context_body["capabilities"] || %{}
    selection = executor_selection(attempt, configured)

    Request.new(%{
      attempt_id: attempt.attempt_id,
      work_item_id: attempt.work_item.work_item_id,
      mission_id: attempt.work_item.mission.mission_id,
      context_bundle: %{
        id: attempt.context_bundle.context_bundle_id,
        digest: attempt.context_digest,
        body: context_body
      },
      role_binding: get_in(attempt.provenance, ["role_binding"]),
      recipe: context_body["recipe"],
      requirements: %{
        executor_kind: attempt.executor_kind,
        provider: attempt.provider,
        tools: allowed_tools(capabilities),
        disallowed_tools: disallowed_tools(capabilities),
        operations: capabilities["operations"] || [],
        isolation: ["owned_worktree"],
        features: ["cancellation", "heartbeat", "structured_output", "timeout"]
      },
      selection: selection,
      limits: %{
        max_turns: configured["max_turns"],
        max_budget_usd: configured["max_budget_usd"],
        timeout_ms: configured["timeout"]
      },
      workspace: %{
        lease_id: lease.lease_id,
        path: lease.workspace_path,
        isolation: "owned_worktree",
        hermetic: configured["hermetic"]
      },
      instructions: %{
        system: bounded_system_prompt(attempt),
        task: attempt_instruction(attempt)
      },
      output_contract: context_body["output_contract"],
      delivery: %{
        kind: "oban",
        oban_job_id: job.id,
        delivery_attempt: job.attempt,
        max_deliveries: job.max_attempts
      }
    })
  end

  defp bounded_system_prompt(attempt) do
    """
    You are executing one bounded #{attempt_label(attempt)} Attempt in an already-owned Git worktree.
    Change only what the supplied ContextBundle requires. Do not commit, push, open a pull
    request, invoke network tools, delegate, or modify another workspace. Return exactly the
    schema-constrained result. Verification and publication belong to later Attempts.
    """
    |> String.trim()
  end

  defp allowed_tools(%{"tools" => %{"allowed" => tools}}) when is_list(tools), do: tools
  defp allowed_tools(%{"tools" => tools}) when is_list(tools), do: tools
  defp allowed_tools(_capabilities), do: []

  defp disallowed_tools(%{"tools" => %{"disallowed" => tools}}) when is_list(tools), do: tools
  defp disallowed_tools(_capabilities), do: []

  defp classify(%Result{status: :succeeded, output: structured}, changed_files, _job) do
    provider_outcome = value(structured, :outcome)

    case provider_outcome do
      "success" when changed_files != [] ->
        classification("success", "succeeded", value(structured, :summary))

      "success" ->
        classification(
          "semantic_follow_up",
          "partial",
          "provider reported success without a workspace change",
          error_class: "semantic_follow_up",
          error_details: %{reason: "empty_change_set"}
        )

      "semantic_follow_up" ->
        classification(
          "semantic_follow_up",
          "partial",
          value(structured, :summary),
          error_class: "semantic_follow_up",
          error_details: %{reason: value(structured, :reason)}
        )

      "human_question" ->
        classification(
          "human_question",
          "blocked",
          value(structured, :summary),
          error_class: "human_question",
          error_details: %{question: value(structured, :question)},
          question: value(structured, :question)
        )

      "blocked" ->
        classification(
          "blocked",
          "blocked",
          value(structured, :summary),
          error_class: "provider_blocked",
          error_details: %{reason: value(structured, :reason)}
        )

      _invalid ->
        classification(
          "blocked",
          "blocked",
          "provider violated the implementation output contract",
          error_class: "output_contract",
          error_details: %{outcome: provider_outcome}
        )
    end
  end

  defp classify(
         %Result{status: :failed, failure: %Failure{retryable: true} = failure} = result,
         _changed_files,
         job
       ) do
    if job.attempt < job.max_attempts do
      %{
        "retry" => true,
        "verdict" => inspect(failure.details[:reason] || failure.classification),
        "payload" => result.evidence
      }
    else
      classification(
        "retryable_infrastructure",
        "failed",
        "provider infrastructure retries were exhausted",
        error_class: "retryable_infrastructure",
        error_details: %{
          classification: failure.classification,
          reason: inspect(failure.details[:reason] || failure.message)
        }
      )
    end
  end

  defp classify(
         %Result{status: :cancelled, failure: %Failure{classification: :limit} = failure} =
           result,
         _changed_files,
         _job
       ) do
    classification(
      "semantic_follow_up",
      "partial",
      "the configured provider rail stopped the implementation",
      error_class: "semantic_follow_up",
      error_details: %{reason: failure.details[:reason], provider: result.evidence}
    )
  end

  defp classify(%Result{status: :cancelled, failure: failure} = result, _changed_files, _job) do
    classification(
      "blocked",
      "blocked",
      "the provider could not run under the configured environment",
      error_class: "provider_blocked",
      error_details: %{reason: failure.details[:reason], provider: result.evidence}
    )
  end

  defp classify(
         %Result{
           status: :rejected,
           failure: %Failure{classification: :capability_mismatch} = failure
         },
         _changed_files,
         _job
       ) do
    classification(
      "blocked",
      "blocked",
      "no eligible Executor capabilities satisfy the Attempt",
      error_class: "capability_mismatch",
      error_details: failure.details
    )
  end

  defp classify(%Result{status: :failed, failure: failure} = result, _changed_files, _job) do
    classification(
      "blocked",
      "blocked",
      "the Executor could not complete the implementation",
      error_class: "provider_contract",
      error_details: %{
        classification: failure.classification,
        reason: failure.message,
        details: failure.details,
        provider: result.evidence
      }
    )
  end

  defp classify(%Result{} = result, _changed_files, _job) do
    classification(
      "blocked",
      "blocked",
      "the Executor returned an unsupported result",
      error_class: "provider_contract",
      error_details: %{status: result.status}
    )
  end

  defp blocked_classification(reason) do
    classification(
      "blocked",
      "blocked",
      "implementation preflight failed",
      error_class: "implementation_preflight",
      error_details: %{reason: inspect(reason)}
    )
  end

  defp classification(category, attempt_state, summary, options \\ []) do
    %{
      "retry" => false,
      "category" => category,
      "attempt_state" => attempt_state,
      "summary" => summary || category,
      "error_class" => options[:error_class],
      "error_details" => normalize(options[:error_details]),
      "question" => options[:question]
    }
  end

  defp retry_verdict(%Result{failure: %Failure{} = failure}) do
    {:error, failure.details[:reason] || {:executor_failure, failure.classification}}
  end

  defp preflight_executor_result(attempt, reason) do
    {:ok, version} = Executor.version(executor(attempt))

    %Result{
      attempt_id: attempt.attempt_id,
      status: :rejected,
      output: nil,
      usage: %{},
      continuation: nil,
      transcript_refs: [],
      artifacts: [],
      cancellation: nil,
      failure: %Failure{
        classification: :provider_refusal,
        message: "implementation preflight failed",
        retryable: false,
        details: %{reason: inspect(reason)}
      },
      evidence: %{"kind" => "preflight", "reason" => inspect(reason)},
      executor: Map.from_struct(version)
    }
  end

  defp normalize_failure(nil), do: nil
  defp normalize_failure(%Failure{} = failure), do: failure |> Map.from_struct() |> normalize()

  defp job_changeset(attempt, routine_id) do
    args = %{"attempt_id" => attempt.attempt_id, "routine_id" => routine_id}

    options = [
      meta: %{
        "agent_id" => routine_id,
        "legacy_routine_id" => routine_id,
        "attempt_id" => attempt.attempt_id,
        "work_item_id" => attempt.work_item.work_item_id,
        "mission_id" => attempt.work_item.mission.mission_id
      }
    ]

    case attempt.provider do
      "claude" -> ClaudeAttemptJob.new(args, options)
      "codex" -> CodexAttemptJob.new(args, options)
    end
  end

  defp bind_job(attempt_id, job_id) do
    case Attempts.start(attempt_id, %{oban_job_id: job_id}) do
      {:ok, _attempt} -> :ok
      {:error, {:attempt_terminal, _state}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_running(%Attempt{state: "queued"} = attempt, job) do
    Attempts.start(attempt.attempt_id, %{oban_job_id: job.id})
  end

  defp ensure_running(%Attempt{state: "running"} = attempt, job) do
    Attempts.start(attempt.attempt_id, %{oban_job_id: job.id})
  end

  defp dispatchable(%Attempt{} = attempt, routine_id, options) do
    expected_routine = get_in(attempt.provenance, ["legacy_routine_id"])
    purpose = get_in(attempt.provenance, ["purpose"])

    cond do
      attempt.executor_kind != "model" ->
        {:error, :model_attempt_required}

      attempt.provider not in ~w(claude codex) ->
        {:error, :supported_model_provider_required}

      provider_matches?(attempt, options) != :ok ->
        {:error, :model_provider_mismatch}

      purpose not in ~w(github_issue_implementation github_issue_repair) ->
        {:error, :github_issue_model_attempt_required}

      purpose == "github_issue_repair" and
          get_in(attempt.provenance, ["repair_disposition", "kind"]) != "semantic_repair" ->
        {:error, :semantic_repair_disposition_required}

      expected_routine != routine_id ->
        {:error, :legacy_routine_mismatch}

      true ->
        :ok
    end
  end

  defp active_owner(attempt, work_item) do
    valid? =
      work_item.state == "active" and
        work_item.phase == active_phase(attempt) and
        work_item.active_attempt_id == attempt.attempt_id and
        work_item.version == attempt.expected_work_item_version + 1

    if valid?, do: :ok, else: {:error, :attempt_not_active_owner}
  end

  defp repair_attempt?(attempt),
    do: get_in(attempt.provenance || %{}, ["purpose"]) == "github_issue_repair"

  defp active_phase(attempt),
    do:
      if(
        repair_attempt?(attempt),
        do: get_in(attempt.provenance || %{}, ["active_phase"]) || "repairing",
        else: "implementing"
      )

  defp attempt_kind(attempt) do
    cond do
      get_in(attempt.provenance || %{}, ["repair_origin"]) == "github_review" ->
        "#{attempt.provider}_review_repair"

      repair_attempt?(attempt) ->
        "#{attempt.provider}_repair"

      true ->
        "#{attempt.provider}_implementation"
    end
  end

  defp attempt_label(attempt),
    do:
      if(
        get_in(attempt.provenance || %{}, ["repair_origin"]) == "github_review",
        do: "review repair",
        else: if(repair_attempt?(attempt), do: "semantic repair", else: "implementation")
      )

  defp attempt_instruction(attempt) do
    cond do
      get_in(attempt.provenance || %{}, ["repair_origin"]) == "github_review" ->
        "Address only the accepted GitHub observation described by this exact ContextBundle."

      repair_attempt?(attempt) ->
        "Repair only the focused failure described by this exact ContextBundle."

      true ->
        "Implement the approved WorkItem described by this exact ContextBundle."
    end
  end

  defp repair_evidence(attempt, evidence) do
    %{
      disposition: get_in(attempt.provenance, ["repair_disposition"]),
      result: evidence
    }
  end

  defp failure_evidence(attempt, evidence, disposition) do
    if repair_attempt?(attempt) do
      %{repair_failure: repair_evidence(attempt, evidence)}
      |> maybe_put_map(:repair_disposition, disposition)
    else
      %{implementation_failure: evidence}
    end
  end

  defp success_evidence(attempt, evidence) do
    if repair_attempt?(attempt),
      do: %{repair: repair_evidence(attempt, evidence)},
      else: %{implementation: evidence}
  end

  defp provider_disposition(attempt, classification, evidence, kind) do
    attrs = %{
      kind: kind,
      reason: classification["summary"] || classification["category"],
      source_attempt_id: attempt.attempt_id,
      failure_artifact_id: evidence.provider_checkpoint_artifact_id,
      question: if(kind == "human_ask", do: classification["question"])
    }

    {:ok, disposition} = Disposition.new(attrs)
    Disposition.render(disposition)
  end

  defp maybe_put_map(map, _key, nil), do: map
  defp maybe_put_map(map, key, value), do: Map.put(map, key, value)

  defp checkpoint(attempt), do: Artifacts.get(artifact_ids(attempt).checkpoint)

  defp checkpoint_matches(attempt, body) do
    if body["attempt_id"] == attempt.attempt_id and
         body["context_digest"] == attempt.context_digest do
      :ok
    else
      {:error, :provider_checkpoint_mismatch}
    end
  end

  defp artifact_ids(attempt) do
    %{
      checkpoint: "#{attempt.provider}-result:#{attempt.attempt_id}",
      changed_files: "changed-files:#{attempt.attempt_id}",
      diff: "implementation-diff:#{attempt.attempt_id}"
    }
  end

  defp put_once(attempt, artifact_id, body, kind, media_type, options) do
    case Artifacts.get(artifact_id) do
      nil ->
        attrs = artifact_attrs(attempt, artifact_id, kind, media_type)
        put_options = artifact_put_options(options)

        case Artifacts.put(
               attempt.work_item.work_item_id,
               body,
               attrs,
               put_options
             ) do
          {:error, {:artifact_write, :eexist}} ->
            recover_orphan_file(attempt, artifact_id, body, attrs, media_type, options)

          result ->
            result
        end

      %Artifact{} = artifact ->
        existing_artifact(artifact, artifact_id, body)
    end
  end

  defp recover_orphan_file(attempt, artifact_id, body, attrs, media_type, options) do
    path =
      options
      |> Keyword.get(:artifact_dir, default_artifact_dir())
      |> Path.join(artifact_id <> artifact_extension(media_type, options))
      |> Path.expand()

    with {:ok, existing_body} <- File.read(path),
         true <- existing_body == body do
      case Artifacts.get(artifact_id) do
        %Artifact{} = artifact ->
          existing_artifact(artifact, artifact_id, body)

        nil ->
          attrs
          |> Map.merge(%{
            work_item_id: attempt.work_item.work_item_id,
            digest: Artifacts.digest(body),
            location: path,
            size_bytes: byte_size(body)
          })
          |> Artifacts.create()
          |> recover_concurrent_artifact(artifact_id, body)
      end
    else
      false -> {:error, {:artifact_conflict, artifact_id}}
      {:error, reason} -> {:error, {:artifact_recovery, reason}}
    end
  end

  defp recover_concurrent_artifact({:ok, artifact}, _artifact_id, _body),
    do: {:ok, artifact}

  defp recover_concurrent_artifact({:error, reason}, artifact_id, body) do
    case Artifacts.get(artifact_id) do
      %Artifact{} = artifact -> existing_artifact(artifact, artifact_id, body)
      nil -> {:error, reason}
    end
  end

  defp existing_artifact(artifact, artifact_id, body) do
    if artifact.digest == Artifacts.digest(body) do
      {:ok, artifact}
    else
      {:error, {:artifact_conflict, artifact_id}}
    end
  end

  defp artifact_attrs(attempt, artifact_id, kind, media_type) do
    %{
      artifact_id: artifact_id,
      producer_attempt_id: attempt.attempt_id,
      kind: kind,
      media_type: media_type,
      provenance: %{
        context_digest: attempt.context_digest,
        provider: attempt.provider
      },
      retention: %{until: "work_item_terminal"}
    }
  end

  defp executor(%Attempt{provider: "claude"}), do: Claude
  defp executor(%Attempt{provider: "codex"}), do: Codex

  defp query_fun_key(%Attempt{provider: "claude"}), do: :claude_attempt_query_fun
  defp query_fun_key(%Attempt{provider: "codex"}), do: :codex_attempt_query_fun

  defp expected_provider(options), do: Keyword.get(options, :expected_provider)

  defp provider_matches?(attempt, options) do
    if expected_provider(options) in [nil, attempt.provider],
      do: :ok,
      else: {:error, :model_provider_mismatch}
  end

  defp executor_selection(attempt, configured) do
    case get_in(attempt.provenance || %{}, ["executor_selection"]) do
      selection when is_map(selection) ->
        normalize(selection)

      _missing ->
        configured
        |> Map.take(~w(model effort agent))
        |> maybe_put_map("profile", attempt.profile)
    end
  end

  defp artifact_put_options(options) do
    [artifact_dir: options[:artifact_dir]]
    |> maybe_put(:extension, options[:extension])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp artifact_extension(media_type, options) do
    options[:extension] || default_extension(media_type)
  end

  defp default_extension("application/json"), do: ".json"
  defp default_extension("text/markdown"), do: ".md"
  defp default_extension("text/plain"), do: ".txt"
  defp default_extension(_media_type), do: ".bin"

  defp default_artifact_dir,
    do: Custode.Home.resolve_in(&Custode.Home.data_dir/0, "artifacts")

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

  defp after_checkpoint(checkpoint, options) do
    case Keyword.get(options, :after_checkpoint, fn _artifact -> :ok end).(checkpoint) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)

  defp normalize(nil), do: nil

  defp normalize(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), normalize(value)} end)

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value) when is_atom(value), do: to_string(value)
  defp normalize(value), do: value

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
