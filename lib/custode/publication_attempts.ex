defmodule Custode.PublicationAttempts do
  @moduledoc """
  Durable publication of one verified WorkItem as a draft pull request.

  The Attempt owns orchestration and evidence. Consequential Git and GitHub
  effects are separate OperationCalls with stable keys and effect-level
  reconciliation.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundles,
    OperationCall,
    PublicationAttemptJob,
    Repo,
    Routine,
    WorkItems,
    WorkProcess,
    WorkspaceLeases
  }

  alias Custode.Operations.Git.PublishBranch
  alias Custode.Operations.GitHub.OpenPr
  alias Custode.Workspace.Git

  @doc "Insert or recover the one physical job for a publication Attempt."
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

  @doc "Publish, persist evidence, finish, and move the WorkItem to durable waiting."
  def perform(%Oban.Job{} = job, options \\ []) when is_list(options) do
    case job.args do
      %{"attempt_id" => attempt_id, "routine_id" => routine_id} ->
        perform(job, attempt_id, routine_id, options)

      _invalid ->
        {:discard, :invalid_publication_attempt}
    end
  end

  defp perform(job, attempt_id, routine_id, options) do
    case Attempts.get(attempt_id) do
      nil ->
        {:discard, {:unknown_attempt, attempt_id}}

      %Attempt{} = attempt when attempt.state in ~w(succeeded failed cancelled blocked partial) ->
        advance(attempt, job)

      %Attempt{} = attempt ->
        run(attempt, routine_id, job, options)
    end
  end

  defp run(attempt, routine_id, job, options) do
    with {:ok, running} <- ensure_running(attempt, job),
         {:ok, runtime} <- runtime(running, routine_id, options) do
      case publish(running, runtime, options) do
        {:ok, publication} ->
          finish_success(running, publication, job)

        {:retry, reason} ->
          {:error, reason}

        {:crash, reason} ->
          {:error, reason}

        {:error, reason} ->
          finish_failure(running, reason, job)
      end
    else
      {:error, reason} ->
        finish_failure(attempt, reason, job)
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
         {:ok, publication} <- publication_input(context_body),
         :ok <- publication_matches(attempt, lease, publication) do
      {:ok,
       %{
         routine: routine,
         lease: lease,
         publication: publication
       }}
    else
      nil -> {:error, :publication_runtime_scope_missing}
      state when is_binary(state) -> {:error, {:workspace_lease_not_active, state}}
      {:error, _reason} = error -> error
    end
  end

  defp publish(attempt, runtime, options) do
    git_arguments = git_arguments(attempt, runtime)

    with {:ok, git_call} <-
           operation_result(
             PublishBranch.dispatch(
               git_arguments,
               operation_options(attempt, options, "git")
             )
           ),
         {:ok, branch_artifact} <-
           put_artifact(
             attempt,
             "publication-branch:#{attempt.attempt_id}",
             "branch",
             branch_body(git_call),
             git_call.call_id,
             options
           ),
         {:ok, commit_artifact} <-
           put_artifact(
             attempt,
             "publication-commit:#{attempt.attempt_id}",
             "commit",
             commit_body(git_call),
             git_call.call_id,
             options
           ) do
      with :ok <- after_effect(:after_git, git_call, options),
           github_arguments <-
             github_arguments(attempt, runtime, git_call.result.commit_sha),
           {:ok, github_call} <-
             operation_result(
               OpenPr.dispatch(
                 github_arguments,
                 operation_options(attempt, options, "github")
               )
             ),
           {:ok, pull_request_artifact} <-
             put_artifact(
               attempt,
               "publication-pull-request:#{attempt.attempt_id}",
               "pull_request",
               pull_request_body(github_call),
               github_call.call_id,
               options
             ),
           :ok <- after_effect(:after_pull_request, github_call, options) do
        {:ok,
         %{
           git_call: git_call,
           github_call: github_call,
           branch_artifact: branch_artifact,
           commit_artifact: commit_artifact,
           pull_request_artifact: pull_request_artifact
         }}
      else
        {:retry, _reason} = retry -> retry
        {:error, {:simulated_crash, _reason} = reason} -> {:crash, reason}
        {:error, reason} -> {:error, reason}
      end
    else
      {:retry, _reason} = retry -> retry
      {:error, reason} -> {:error, reason}
    end
  end

  defp operation_result({:ok, %{status: status} = response})
       when status in [:succeeded, :dry_run],
       do: {:ok, response}

  defp operation_result({:ok, %{status: status, call_id: call_id}})
       when status in [:proposed, :waiting, :running],
       do: {:retry, {:publication_operation_waiting, call_id, status}}

  defp operation_result({:error, reason}), do: {:error, reason}

  defp after_effect(name, response, options) do
    case Keyword.get(options, name, fn _response -> :ok end).(response) do
      :ok -> :ok
      {:error, reason} -> {:error, {:simulated_crash, reason}}
    end
  end

  defp finish_success(attempt, publication, job) do
    pull_request = publication.github_call.result

    attrs = %{
      state: "succeeded",
      usage: %{cost_usd: 0, duration_ms: 0, commands: 2},
      outcome: %{
        kind: "github_draft_publication",
        classification: "published",
        operation_call_ids: [
          publication.git_call.call_id,
          publication.github_call.call_id
        ],
        artifacts: %{
          branch_artifact_id: publication.branch_artifact.artifact_id,
          commit_artifact_id: publication.commit_artifact.artifact_id,
          pull_request_artifact_id: publication.pull_request_artifact.artifact_id
        },
        pull_request: pull_request,
        proposal: %{
          state: "waiting",
          phase: "awaiting_review",
          waiting_condition: %{
            kind: "external_event",
            name: "github_pull_request",
            repository: pull_request.repository,
            number: pull_request.number,
            head_sha: pull_request.head_sha
          },
          evidence: %{
            pull_request: %{
              artifact_id: publication.pull_request_artifact.artifact_id,
              operation_call_id: publication.github_call.call_id,
              repository: pull_request.repository,
              number: pull_request.number,
              url: pull_request.url,
              draft: pull_request.draft,
              head_branch: pull_request.head_branch,
              head_sha: pull_request.head_sha,
              commit_artifact_id: publication.commit_artifact.artifact_id,
              branch_artifact_id: publication.branch_artifact.artifact_id
            }
          }
        }
      }
    }

    with {:ok, finished} <- Attempts.finish(attempt.attempt_id, attrs) do
      advance(finished, job)
    end
  end

  defp finish_failure(attempt, reason, job) do
    case Attempts.get(attempt.attempt_id) do
      %Attempt{} = current when current.state in ~w(queued running) ->
        with {:ok, running} <- ensure_running(current, job),
             {:ok, finished} <-
               Attempts.finish(
                 running.attempt_id,
                 failure_attrs(running, reason)
               ) do
          advance(finished, job)
        end

      %Attempt{} = terminal ->
        advance(terminal, job)

      nil ->
        {:discard, {:unknown_attempt, attempt.attempt_id}}
    end
  end

  defp failure_attrs(attempt, reason) do
    stale? = match?({:stale, _reason}, reason) or match?({:stale, _reason, _observed}, reason)
    operation_call_ids = operation_call_ids(attempt.attempt_id)

    %{
      state: if(stale?, do: "cancelled", else: "failed"),
      usage: %{cost_usd: 0, duration_ms: 0, commands: length(operation_call_ids)},
      error_class: if(stale?, do: "stale", else: "publication_failure"),
      error_details: %{reason: inspect(reason)},
      outcome: %{
        kind: "github_draft_publication",
        classification: if(stale?, do: "stale", else: "publication_failure"),
        reason: inspect(reason),
        operation_call_ids: operation_call_ids,
        proposal: %{
          state: "blocked",
          phase: "publishing",
          blocked_reason: %{
            code: if(stale?, do: "publication_stale", else: "publication_failed"),
            reason: inspect(reason)
          },
          evidence: %{
            publication_failure: %{
              reason: inspect(reason),
              operation_call_ids: operation_call_ids
            }
          }
        }
      }
    }
  end

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
                 correlation_id: "publication-attempt:#{attempt.attempt_id}",
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

  defp publication_input(context_body) do
    case context_body["publication"] do
      %{} = publication -> {:ok, publication}
      _missing -> {:error, :publication_context_missing}
    end
  end

  defp publication_matches(attempt, lease, publication) do
    valid? =
      lease.lease_id == get_in(attempt.provenance, ["workspace_lease_id"]) and
        lease.branch == publication["branch"] and
        get_in(attempt.provenance, ["workspace_revision"]) ==
          publication["expected_workspace_revision"]

    if valid?, do: :ok, else: {:error, :publication_context_mismatch}
  end

  defp git_arguments(attempt, runtime) do
    publication = runtime.publication
    lease = runtime.lease

    %{
      work_item_id: attempt.work_item.work_item_id,
      attempt_id: attempt.attempt_id,
      lease_id: lease.lease_id,
      repository: publication["repository"],
      repository_path: lease.repository_path,
      workspace_path: lease.workspace_path,
      branch: publication["branch"],
      remote: publication["remote"],
      expected_work_item_version: attempt.work_item.version,
      expected_workspace_revision: publication["expected_workspace_revision"],
      expected_head_revision: publication["expected_head_revision"],
      expected_changed_files: publication["expected_changed_files"],
      commit_message: publication["commit_message"]
    }
  end

  defp github_arguments(attempt, runtime, commit_sha) do
    publication = runtime.publication

    %{
      work_item_id: attempt.work_item.work_item_id,
      attempt_id: attempt.attempt_id,
      lease_id: runtime.lease.lease_id,
      repository: publication["repository"],
      remote: publication["remote"],
      expected_work_item_version: attempt.work_item.version,
      expected_head_sha: commit_sha,
      head_branch: publication["branch"],
      base_branch: publication["base_branch"],
      title: publication["title"],
      body: publication["body"]
    }
  end

  defp operation_options(attempt, options, effect) do
    [
      mission_id: attempt.work_item.mission.mission_id,
      idempotency_key: "publication:#{attempt.attempt_id}:#{effect}",
      correlation_id: "publication-attempt:#{attempt.attempt_id}",
      causation_id: attempt.attempt_id,
      registry: options[:registry]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Keyword.put_new(:registry, Custode.OperationRegistry.default())
  end

  defp branch_body(call) do
    %{
      operation_call_id: call.call_id,
      repository: call.result.repository,
      branch: call.result.branch,
      remote: call.result.remote,
      source: call.result.source
    }
  end

  defp commit_body(call) do
    %{
      operation_call_id: call.call_id,
      repository: call.result.repository,
      branch: call.result.branch,
      commit_sha: call.result.commit_sha,
      source: call.result.source
    }
  end

  defp pull_request_body(call) do
    call.result
    |> Map.put(:operation_call_id, call.call_id)
  end

  defp put_artifact(attempt, artifact_id, kind, body, call_id, options) do
    encoded = Jason.encode!(body)

    case Artifacts.get(artifact_id) do
      %Artifact{} = artifact ->
        if artifact.digest == Artifacts.digest(encoded),
          do: {:ok, artifact},
          else: {:error, {:artifact_conflict, artifact_id}}

      nil ->
        Artifacts.put(
          attempt.work_item.work_item_id,
          encoded,
          %{
            artifact_id: artifact_id,
            producer_attempt_id: attempt.attempt_id,
            kind: kind,
            media_type: "application/json",
            provenance: %{operation_call_id: call_id},
            retention: %{until: "work_item_terminal"}
          },
          artifact_options(options)
        )
    end
  end

  defp operation_call_ids(attempt_id) do
    Repo.all(
      from(call in OperationCall,
        where: call.attempt_id == ^attempt_id,
        order_by: [asc: call.inserted_at],
        select: call.call_id
      )
    )
  end

  defp dispatchable(%Attempt{} = attempt, routine_id) do
    cond do
      attempt.executor_kind != "deterministic" ->
        {:error, :deterministic_publication_attempt_required}

      attempt.provider != "custode" ->
        {:error, :custode_publication_attempt_required}

      get_in(attempt.provenance, ["purpose"]) != "github_issue_publication" ->
        {:error, :publication_attempt_required}

      get_in(attempt.provenance, ["legacy_routine_id"]) != routine_id ->
        {:error, :legacy_routine_mismatch}

      true ->
        :ok
    end
  end

  defp active_owner(attempt) do
    work_item = attempt.work_item

    valid? =
      work_item.state == "active" and
        work_item.phase == "publishing" and
        work_item.active_attempt_id == attempt.attempt_id and
        work_item.version == attempt.expected_work_item_version + 1

    if valid?, do: :ok, else: {:error, :attempt_not_active_owner}
  end

  defp heartbeat(lease_id, options) do
    heartbeat_options =
      [git: options[:git]]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    WorkspaceLeases.heartbeat(lease_id, heartbeat_options)
  end

  defp job_changeset(attempt, routine_id) do
    args = %{"attempt_id" => attempt.attempt_id, "routine_id" => routine_id}

    PublicationAttemptJob.new(args,
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

  defp artifact_options(options) do
    [artifact_dir: options[:artifact_dir]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
