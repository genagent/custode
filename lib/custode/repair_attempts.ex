defmodule Custode.RepairAttempts do
  @moduledoc """
  Durable execution for reviewed deterministic repair handlers.

  A command claim is persisted before execution. A retry reuses a completed
  result and never silently reruns an interrupted command.
  """

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundles,
    GitHubIssueVertical,
    RepairAttemptJob,
    Routine,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.Verification.{CommandSpec, Runner}
  alias Custode.Workspace.Git

  @doc "Insert or recover the one physical job for a deterministic repair Attempt."
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

  @doc "Run, checkpoint, finish, and advance one deterministic repair Attempt."
  def perform(%Oban.Job{} = job, options \\ []) when is_list(options) do
    case job.args do
      %{"attempt_id" => attempt_id, "routine_id" => routine_id} ->
        perform(job, attempt_id, routine_id, options)

      _invalid ->
        {:discard, :invalid_repair_attempt}
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

          result = Artifacts.get(result_id(attempt)) ->
            recover(attempt, result, job, options)

          true ->
            run(attempt, routine_id, job, options)
        end
    end
  end

  defp run(attempt, routine_id, job, options) do
    with {:ok, running} <- ensure_running(attempt, job),
         {:ok, runtime} <- runtime(running, routine_id, options) do
      with {:ok, result} <- claim_and_run(running, runtime, options),
           :ok <- after_result(result, options) do
        recover(running, result, job, options)
      end
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
         {:ok, handler} <- handler(context_body),
         :ok <- handler_matches(attempt, handler),
         {:ok, observed_revision} <- Git.workspace_revision(lease.workspace_path),
         :ok <- expected_revision(attempt, observed_revision) do
      {:ok,
       %{
         routine: routine,
         lease: lease,
         context_body: context_body,
         handler: handler,
         workspace_revision: observed_revision
       }}
    else
      nil -> {:error, :repair_runtime_scope_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp claim_and_run(attempt, runtime, options) do
    case Artifacts.get(claim_id(attempt)) do
      %Artifact{} ->
        persist_result(
          attempt,
          interrupted_result(attempt, runtime),
          options
        )

      nil ->
        with {:ok, _claim} <- put_claim(attempt, runtime, options) do
          result = execute_handler(attempt, runtime, options)
          persist_result(attempt, result, options)
        end
    end
  end

  defp execute_handler(attempt, %{handler: :verification_retry} = runtime, _options) do
    base_result(attempt, runtime, %{
      "status" => "pass",
      "reason" => "verification retry authorized by bounded policy",
      "exit_code" => nil,
      "duration_ms" => 0,
      "runner_version" => Runner.runner_version(),
      "output" => %{}
    })
  end

  defp execute_handler(attempt, %{handler: %CommandSpec{} = spec} = runtime, options) do
    runner = Keyword.get(options, :runner, Runner)
    runner_options = Keyword.get(options, :runner_options, [])

    result =
      case run_command(runner, spec, runtime.lease.workspace_path, runner_options) do
        {:ok, body} ->
          body

        {:error, reason} ->
          %{
            "name" => spec.name,
            "category" => spec.category,
            "status" => "infrastructure_error",
            "reason" => inspect(reason),
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
            "output" => %{}
          }
      end

    base_result(attempt, runtime, result)
  end

  defp base_result(attempt, runtime, result) do
    post_revision =
      case Git.workspace_revision(runtime.lease.workspace_path) do
        {:ok, revision} -> revision
        {:error, reason} -> %{"error" => inspect(reason)}
      end

    result
    |> Map.put("attempt_id", attempt.attempt_id)
    |> Map.put("disposition", get_in(attempt.provenance, ["repair_disposition"]))
    |> Map.put("policy", get_in(attempt.provenance, ["repair_policy"]))
    |> Map.put("workspace_revision_before", runtime.workspace_revision)
    |> Map.put("workspace_revision_after", post_revision)
  end

  defp interrupted_result(attempt, runtime) do
    base_result(attempt, runtime, %{
      "status" => "infrastructure_error",
      "reason" => "execution_interrupted_after_durable_claim",
      "exit_code" => nil,
      "duration_ms" => 0,
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
      "output" => %{}
    })
  end

  defp put_claim(attempt, runtime, options) do
    body =
      Jason.encode!(%{
        "attempt_id" => attempt.attempt_id,
        "context_digest" => attempt.context_digest,
        "disposition" => get_in(attempt.provenance, ["repair_disposition"]),
        "workspace_revision" => runtime.workspace_revision["revision"]
      })

    put_once(
      attempt,
      claim_id(attempt),
      body,
      "repair_claim",
      %{
        disposition: get_in(attempt.provenance, ["repair_disposition", "kind"]),
        workspace_revision: runtime.workspace_revision["revision"]
      },
      options
    )
  end

  defp persist_result(attempt, result, options) do
    put_once(
      attempt,
      result_id(attempt),
      Jason.encode!(result),
      "repair_result",
      %{
        disposition: get_in(attempt.provenance, ["repair_disposition", "kind"]),
        source_attempt_id: attempt.caused_by_attempt && attempt.caused_by_attempt.attempt_id
      },
      options
    )
  end

  defp recover(attempt, artifact, job, options) do
    with {:ok, body} <- read_json_artifact(artifact),
         :ok <- result_matches(attempt, body),
         {:ok, finished} <-
           Attempts.finish(
             attempt.attempt_id,
             finish_attrs(attempt, body, artifact)
           ) do
      advance(finished, job, options)
    end
  end

  defp finish_attrs(attempt, body, artifact) do
    status = body["status"]
    success? = status == "pass"

    %{
      state: if(success?, do: "succeeded", else: attempt_state(status)),
      usage: %{
        cost_usd: 0,
        duration_ms: body["duration_ms"] || 0,
        commands: if(body["name"], do: 1, else: 0)
      },
      error_class: if(success?, do: nil, else: status),
      error_details: if(success?, do: nil, else: %{reason: body["reason"]}),
      outcome: %{
        kind: "deterministic_repair",
        classification: status,
        disposition: get_in(attempt.provenance, ["repair_disposition"]),
        artifacts: %{
          repair_result_artifact_id: artifact.artifact_id,
          failure_artifact_id: artifact.artifact_id
        },
        workspace_revision: body["workspace_revision_after"],
        proposal: %{
          state: "ready",
          phase: if(success?, do: "verification_ready", else: "repair_ready"),
          evidence: %{
            repair: %{
              disposition: get_in(attempt.provenance, ["repair_disposition"]),
              result_artifact_id: artifact.artifact_id
            }
          }
        }
      }
    }
  end

  defp finish_preflight_failure(attempt, routine_id, reason, job, options) do
    case Attempts.get(attempt.attempt_id) do
      %Attempt{} = current when current.state in ~w(queued running) ->
        with {:ok, running} <- ensure_running(current, job),
             body <- preflight_result(running, reason),
             {:ok, artifact} <- persist_result(running, body, options) do
          recover(running, artifact, job, options)
        end

      %Attempt{} = terminal ->
        advance(terminal, job, options)

      nil ->
        {:discard, {:unknown_attempt, attempt.attempt_id, routine_id}}
    end
  end

  defp preflight_result(attempt, reason) do
    %{
      "attempt_id" => attempt.attempt_id,
      "disposition" => get_in(attempt.provenance, ["repair_disposition"]),
      "policy" => get_in(attempt.provenance, ["repair_policy"]),
      "status" => "policy_refusal",
      "reason" => inspect(reason),
      "exit_code" => nil,
      "duration_ms" => 0,
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
      "workspace_revision_before" => nil,
      "workspace_revision_after" => nil,
      "output" => %{}
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
                 correlation_id: "repair-attempt:#{attempt.attempt_id}",
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

    if work_item.state == "ready" and work_item.phase in ~w(verification_ready repair_ready) do
      schedule_options =
        [enqueue_fun: options[:vertical_enqueue_fun]]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case GitHubIssueVertical.schedule_work_item(
             job.args["routine_id"],
             work_item.work_item_id,
             schedule_options
           ) do
        {:ok, _job} -> :ok
        {:error, reason} -> {:error, {:repair_successor_enqueue_failed, reason}}
      end
    else
      :ok
    end
  end

  defp transition_applied?(work_item, proposal) when is_map(proposal) do
    work_item.state == value(proposal, :state) and work_item.phase == value(proposal, :phase)
  end

  defp transition_applied?(_work_item, _proposal), do: false

  defp dispatchable(%Attempt{} = attempt, routine_id) do
    expected_routine = get_in(attempt.provenance, ["legacy_routine_id"])
    disposition = get_in(attempt.provenance, ["repair_disposition", "kind"])

    cond do
      attempt.executor_kind != "deterministic" ->
        {:error, :deterministic_repair_attempt_required}

      attempt.provider != "custode" ->
        {:error, :custode_repair_handler_required}

      get_in(attempt.provenance, ["purpose"]) != "github_issue_repair" ->
        {:error, :repair_attempt_required}

      disposition not in ~w(infrastructure_retry mechanical_repair) ->
        {:error, :deterministic_repair_disposition_required}

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
        work_item.phase == "repairing" and
        work_item.active_attempt_id == attempt.attempt_id and
        work_item.version == attempt.expected_work_item_version + 1

    if valid?, do: :ok, else: {:error, :attempt_not_active_owner}
  end

  defp handler(context_body) do
    case get_in(context_body, ["recipe", "repair"]) do
      %{"name" => "verification_retry", "version" => "1"} ->
        {:ok, :verification_retry}

      %{} = spec ->
        CommandSpec.new(spec)

      _missing ->
        {:error, :repair_handler_missing}
    end
  end

  defp handler_matches(attempt, :verification_retry) do
    if get_in(attempt.provenance, ["repair_disposition", "handler"]) ==
         "verification_retry",
       do: :ok,
       else: {:error, :repair_handler_mismatch}
  end

  defp handler_matches(attempt, %CommandSpec{name: "repair_format"}) do
    if get_in(attempt.provenance, ["repair_disposition", "handler"]) == "elixir_format",
      do: :ok,
      else: {:error, :repair_handler_mismatch}
  end

  defp handler_matches(_attempt, _handler), do: {:error, :repair_handler_mismatch}

  defp expected_revision(attempt, observed) do
    expected = get_in(attempt.provenance, ["workspace_revision"])

    if expected == observed["revision"],
      do: :ok,
      else:
        {:error,
         {:workspace_revision_changed, %{expected: expected, observed: observed["revision"]}}}
  end

  defp heartbeat(lease_id, options) do
    heartbeat_options =
      [git: options[:git]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    WorkspaceLeases.heartbeat(lease_id, heartbeat_options)
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

  defp result_matches(attempt, body) do
    if body["attempt_id"] == attempt.attempt_id and
         get_in(body, ["disposition", "kind"]) ==
           get_in(attempt.provenance, ["repair_disposition", "kind"]) do
      :ok
    else
      {:error, :repair_result_mismatch}
    end
  end

  defp after_result(artifact, options) do
    case Keyword.get(options, :after_result, fn _artifact -> :ok end).(artifact) do
      :ok -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp run_command(runner, spec, path, options) when is_function(runner, 3),
    do: runner.(spec, path, options)

  defp run_command(runner, spec, path, options), do: runner.run(spec, path, options)

  defp job_changeset(attempt, routine_id) do
    args = %{"attempt_id" => attempt.attempt_id, "routine_id" => routine_id}

    RepairAttemptJob.new(args,
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

  defp attempt_state("cancellation"), do: "cancelled"
  defp attempt_state(_status), do: "failed"

  defp claim_id(attempt), do: "repair-claim:#{attempt.attempt_id}"
  defp result_id(attempt), do: "repair-result:#{attempt.attempt_id}"

  defp artifact_options(options) do
    [artifact_dir: options[:artifact_dir]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
