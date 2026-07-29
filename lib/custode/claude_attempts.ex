defmodule Custode.ClaudeAttempts do
  @moduledoc """
  The narrow Claude adapter for implementation and focused semantic repair
  Attempts in the first repository vertical.

  Durable Attempt and Artifact records own the execution. The Oban job carries
  only stable IDs, and a provider-result checkpoint prevents a crash after a
  paid call from causing another call.
  """

  alias ClaudeWrapper.{Error, Result}

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ClaudeAttemptJob,
    ContextBundles,
    GitHubIssueContext,
    GitHubIssueVertical,
    Routine,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.Repair.Disposition
  alias Custode.Workspace.Git

  @rail_stops ~w(budget_exceeded max_budget_exceeded max_turns_exceeded)a

  @doc "Insert or recover the one physical job for a queued logical Attempt."
  def dispatch(attempt_id, routine_id, options \\ [])
      when is_binary(attempt_id) and is_binary(routine_id) do
    enqueue = Keyword.get(options, :enqueue_fun, &Oban.insert/1)

    with %Attempt{} = attempt <- Attempts.get(attempt_id),
         :ok <- dispatchable(attempt, routine_id),
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

  def perform(%Oban.Job{}), do: {:discard, :invalid_claude_attempt}

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
        {:discard, :invalid_claude_attempt}
    end
  end

  defp perform(job, attempt_id, routine_id, options) do
    case Attempts.get(attempt_id) do
      nil ->
        {:discard, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt ->
        cond do
          Attempt.terminal?(attempt) ->
            advance(attempt, job, options)

          checkpoint = checkpoint(attempt) ->
            recover_checkpoint(attempt, checkpoint, job, options)

          true ->
            run(attempt, routine_id, job, options)
        end
    end
  end

  defp run(attempt, routine_id, job, options) do
    with {:ok, running} <- ensure_running(attempt, job),
         {:ok, runtime} <- runtime(running, routine_id, options),
         {verdict, payload} <- provider_run(runtime.args, job, options),
         {:ok, changed_files} <- Git.changed_files(runtime.lease.workspace_path),
         {:ok, diff} <- Git.diff(runtime.lease.workspace_path) do
      classification = classify(verdict, payload, changed_files, job)

      if classification["retry"] do
        verdict
      else
        persist_and_finish(
          running,
          runtime,
          payload,
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

  defp runtime(attempt, routine_id, options) do
    with :ok <- dispatchable(attempt, routine_id),
         routine when not is_nil(routine) <- Routine.get(routine_id),
         work_item = attempt.work_item,
         :ok <- active_owner(attempt, work_item),
         lease when not is_nil(lease) <- WorkspaceLeases.get_for_work_item(work_item.work_item_id),
         "active" <- lease.state,
         {:ok, _lease} <- heartbeat(lease.lease_id, options),
         {:ok, context_body} <- ContextBundles.body(attempt.context_bundle) do
      {:ok,
       %{
         routine: routine,
         work_item: work_item,
         lease: lease,
         context_body: context_body,
         args: provider_args(routine, lease, attempt, context_body)
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

  defp provider_run(args, job, options) do
    run_options = [job: job]

    query_fun =
      options[:query_fun] || Application.get_env(:custode, :claude_attempt_query_fun)

    run_options =
      if query_fun, do: Keyword.put(run_options, :query_fun, query_fun), else: run_options

    ObanClaude.run(args, run_options)
  end

  defp persist_and_finish(
         attempt,
         runtime,
         payload,
         classification,
         changed_files,
         diff,
         job,
         options
       ) do
    ids = artifact_ids(attempt.attempt_id)
    usage = usage(payload)
    continuation = continuation(payload)

    checkpoint_body = %{
      "attempt_id" => attempt.attempt_id,
      "context_digest" => attempt.context_digest,
      "workspace_lease_id" => runtime.lease.lease_id,
      "provider" => provider_payload(payload),
      "classification" => classification,
      "usage" => usage,
      "provider_continuation" => continuation,
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
             classification <- blocked_classification(reason) do
          persist_and_finish(
            running,
            runtime,
            reason,
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
                 correlation_id: "claude-attempt:#{attempt.attempt_id}",
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

  defp provider_args(routine, lease, attempt, context_body) do
    configured = Routine.tick_args(routine)["start"]["args"]

    configured
    |> Map.take(~w(model effort max_turns max_budget_usd timeout agent hermetic))
    |> Map.merge(%{
      "working_dir" => lease.workspace_path,
      "permission_mode" => "accept_edits",
      "allowed_tools" => GitHubIssueContext.allowed_tools(),
      "disallowed_tools" => GitHubIssueContext.disallowed_tools(),
      "json_schema" => Jason.encode!(GitHubIssueContext.output_contract()),
      "append_system_prompt" => bounded_system_prompt(attempt),
      "prompt" => attempt_prompt(attempt, context_body)
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

  defp attempt_prompt(attempt, context_body) do
    """
    #{attempt_instruction(attempt)}

    ContextBundle digest: #{attempt.context_digest}

    #{Jason.encode!(context_body, pretty: true)}
    """
    |> String.trim()
  end

  defp classify(:ok, %Result{} = result, changed_files, _job) do
    structured = ObanClaude.structured(result)
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

  defp classify({:error, reason}, payload, _changed_files, job) do
    if job.attempt < job.max_attempts do
      %{
        "retry" => true,
        "verdict" => inspect(reason),
        "payload" => provider_payload(payload)
      }
    else
      classification(
        "retryable_infrastructure",
        "failed",
        "provider infrastructure retries were exhausted",
        error_class: "retryable_infrastructure",
        error_details: %{reason: inspect(reason)}
      )
    end
  end

  defp classify({:cancel, kind}, payload, _changed_files, _job) when kind in @rail_stops do
    classification(
      "semantic_follow_up",
      "partial",
      "the configured provider rail stopped the implementation",
      error_class: "semantic_follow_up",
      error_details: %{reason: inspect(kind), provider: provider_payload(payload)}
    )
  end

  defp classify({:cancel, reason}, payload, _changed_files, _job) do
    classification(
      "blocked",
      "blocked",
      "the provider could not run under the configured environment",
      error_class: "provider_blocked",
      error_details: %{reason: inspect(reason), provider: provider_payload(payload)}
    )
  end

  defp classify(verdict, payload, _changed_files, _job) do
    classification(
      "blocked",
      "blocked",
      "the provider returned an unsupported verdict",
      error_class: "provider_contract",
      error_details: %{verdict: inspect(verdict), provider: provider_payload(payload)}
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

  defp usage(%Result{} = result) do
    %{
      cost_usd: result.cost_usd,
      duration_ms: result.duration_ms,
      num_turns: result.num_turns,
      tokens: ClaudeWrapper.Result.usage(result),
      stop_reason: ClaudeWrapper.Result.stop_reason(result)
    }
  end

  defp usage(payload), do: %{cost_usd: ObanClaude.cost_usd(payload)}

  defp continuation(payload) do
    case ObanClaude.session_id(payload) do
      session_id when is_binary(session_id) -> %{session_id: session_id}
      _missing -> nil
    end
  end

  defp provider_payload(%Result{} = result) do
    %{
      "kind" => "result",
      "result" => result.result,
      "is_error" => result.is_error,
      "session_id" => result.session_id,
      "cost_usd" => result.cost_usd,
      "duration_ms" => result.duration_ms,
      "num_turns" => result.num_turns,
      "usage" => ClaudeWrapper.Result.usage(result),
      "stop_reason" => ClaudeWrapper.Result.stop_reason(result),
      "structured_output" => ObanClaude.structured(result)
    }
  end

  defp provider_payload(%Error{} = error) do
    %{
      "kind" => "error",
      "error_kind" => to_string(error.kind),
      "message" => error.message,
      "reason" => inspect(error.reason),
      "session_id" => ObanClaude.session_id(error),
      "cost_usd" => ObanClaude.cost_usd(error)
    }
  end

  defp provider_payload(payload), do: %{"kind" => "other", "value" => inspect(payload)}

  defp job_changeset(attempt, routine_id) do
    args = %{"attempt_id" => attempt.attempt_id, "routine_id" => routine_id}

    ClaudeAttemptJob.new(args,
      meta: %{
        "agent_id" => routine_id,
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

  defp ensure_running(%Attempt{state: "queued"} = attempt, job) do
    Attempts.start(attempt.attempt_id, %{oban_job_id: job.id})
  end

  defp ensure_running(%Attempt{state: "running"} = attempt, job) do
    Attempts.start(attempt.attempt_id, %{oban_job_id: job.id})
  end

  defp dispatchable(%Attempt{} = attempt, routine_id) do
    expected_routine = get_in(attempt.provenance, ["legacy_routine_id"])
    purpose = get_in(attempt.provenance, ["purpose"])

    cond do
      attempt.executor_kind != "model" ->
        {:error, :model_attempt_required}

      attempt.provider != "claude" ->
        {:error, :claude_attempt_required}

      purpose not in ~w(github_issue_implementation github_issue_repair) ->
        {:error, :github_issue_claude_attempt_required}

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
    do: if(repair_attempt?(attempt), do: "repairing", else: "implementing")

  defp attempt_kind(attempt),
    do: if(repair_attempt?(attempt), do: "claude_repair", else: "claude_implementation")

  defp attempt_label(attempt),
    do: if(repair_attempt?(attempt), do: "semantic repair", else: "implementation")

  defp attempt_instruction(attempt) do
    if repair_attempt?(attempt) do
      "Repair only the focused failure described by this exact ContextBundle."
    else
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

  defp checkpoint(attempt), do: Artifacts.get(artifact_ids(attempt.attempt_id).checkpoint)

  defp checkpoint_matches(attempt, body) do
    if body["attempt_id"] == attempt.attempt_id and
         body["context_digest"] == attempt.context_digest do
      :ok
    else
      {:error, :provider_checkpoint_mismatch}
    end
  end

  defp artifact_ids(attempt_id) do
    %{
      checkpoint: "claude-result:#{attempt_id}",
      changed_files: "changed-files:#{attempt_id}",
      diff: "implementation-diff:#{attempt_id}"
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
        provider: "claude"
      },
      retention: %{until: "work_item_terminal"}
    }
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
