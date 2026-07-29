defmodule Custode.WorkProcessTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Attempt,
    Attempts,
    ContextBundle,
    ContextBundles,
    Mission,
    OperationCall,
    OperationDefinition,
    OperationRegistry,
    Repo,
    WorkCommandJob,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems,
    WorkProcess
  }

  alias Custode.Operations.Authorization
  alias Custode.WorkProcess.Decision

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-process-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "one version claims one logical Attempt and one ID-only Oban command", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("claim")
    bundle = insert_bundle!(work_item, artifact_dir)
    snapshot = attempt_snapshot(work_item, bundle, "attempt-claim")

    assert {:ok, first} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot,
               correlation_id: "corr-claim",
               causation_id: "cause-claim"
             )

    assert first.status == :enqueued
    assert first.decision.action == "dispatch_attempt"
    assert first.decision.attempt["attempt_id"] == "attempt-claim"
    assert first.event.kind == "work.next_action.claimed"
    assert first.event.correlation_id == "corr-claim"
    assert first.event.causation_id == "cause-claim"

    assert first.job.args == %{
             "decision_id" => first.event.event_id,
             "expected_version" => work_item.version,
             "work_item_id" => work_item.work_item_id
           }

    assert Map.keys(first.job.args) |> Enum.sort() ==
             ~w(decision_id expected_version work_item_id)

    assert {:ok, duplicate} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot)

    assert duplicate.event.id == first.event.id
    assert duplicate.job.id == first.job.id
    assert Repo.aggregate(Attempt, :count) == 1
    assert claim_count(work_item) == 1
    assert process_job_count() == 1
  end

  test "the command activates the same Attempt and propagates tracing through typed events", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("perform")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:ok, delivery} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               attempt_snapshot(work_item, bundle, "attempt-perform"),
               correlation_id: "corr-perform",
               causation_id: "cause-perform"
             )

    assert :ok = WorkCommandJob.perform(delivery.job)
    assert :ok = WorkCommandJob.perform(delivery.job)

    attempt = Attempts.get("attempt-perform")
    assert attempt.state == "running"
    assert attempt.oban_job_id == delivery.job.id

    active = WorkItems.get(work_item.work_item_id)
    assert active.state == "active"
    assert active.phase == "preparing_workspace"
    assert active.active_attempt_id == attempt.attempt_id
    assert active.version == work_item.version + 1

    events = WorkItems.list_events(work_item.work_item_id)
    assert Enum.count(events, &(&1.kind == "work.next_action.completed")) == 1

    transition = Enum.find(events, &(&1.kind == "work_item.transitioned"))
    completion = Enum.find(events, &(&1.kind == "work.next_action.completed"))

    assert transition.correlation_id == "corr-perform"
    assert transition.causation_id == delivery.event.event_id
    assert completion.correlation_id == "corr-perform"
    assert completion.causation_id == delivery.event.event_id
  end

  test "overlapping reconcilers converge on the same claim, Attempt, and job", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("concurrent")
    bundle = insert_bundle!(work_item, artifact_dir)
    snapshot = attempt_snapshot(work_item, bundle, "attempt-concurrent")

    results =
      for _index <- 1..3 do
        Task.async(fn ->
          WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot)
        end)
      end
      |> Enum.map(&Task.await(&1, 5_000))

    assert Enum.all?(results, &match?({:ok, _delivery}, &1))

    decision_ids =
      Enum.map(results, fn {:ok, delivery} -> delivery.event.event_id end)

    assert Enum.uniq(decision_ids) |> length() == 1
    assert Repo.aggregate(Attempt, :count) == 1
    assert claim_count(work_item) == 1
    assert process_job_count() == 1
  end

  test "duplicate command callbacks converge on one transition and completion", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("callback-race")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:ok, delivery} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               attempt_snapshot(work_item, bundle, "attempt-callback-race")
             )

    results =
      for _index <- 1..2 do
        Task.async(fn -> WorkCommandJob.perform(delivery.job) end)
      end
      |> Enum.map(&Task.await(&1, 5_000))

    assert results == [:ok, :ok]
    assert WorkItems.get(work_item.work_item_id).version == work_item.version + 1
    assert result_count(delivery.event.event_id) == 1
    assert Attempts.get("attempt-callback-race").state == "running"
  end

  test "stale expected versions schedule and execute no effect", %{artifact_dir: artifact_dir} do
    work_item = insert_work!("stale")
    bundle = insert_bundle!(work_item, artifact_dir)
    snapshot = attempt_snapshot(work_item, bundle, "attempt-stale")

    assert {:error,
            {:stale, :work_item_version_changed,
             %{work_item: %{expected: 99, observed: observed}}}} =
             WorkProcess.reconcile(work_item.work_item_id, 99, snapshot)

    assert observed == work_item.version
    assert Repo.aggregate(Attempt, :count) == 0
    assert process_job_count() == 0

    assert {:ok, claim} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot,
               enqueue: false
             )

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^work_item.id),
      inc: [version: 1]
    )

    assert {:discard, {:stale, :work_item_version_changed}} =
             WorkProcess.perform(
               claim.event.event_id,
               work_item.work_item_id,
               work_item.version,
               77
             )

    assert Attempts.get("attempt-stale").state == "cancelled"
    assert WorkItems.get(work_item.work_item_id).state == "ready"
    assert result_count(claim.event.event_id) == 1
  end

  test "a crash after claim is repaired and a crash after enqueue stays singular", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("delivery-crash")
    bundle = insert_bundle!(work_item, artifact_dir)
    snapshot = attempt_snapshot(work_item, bundle, "attempt-delivery-crash")

    assert {:ok, claimed} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot,
               enqueue: false
             )

    assert claimed.status == :claimed
    assert process_job_count() == 0
    assert Repo.aggregate(Attempt, :count) == 1

    assert {:ok, repaired} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot)

    assert repaired.event.id == claimed.event.id
    assert repaired.status == :enqueued
    assert process_job_count() == 1

    assert {:ok, duplicate} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot)

    assert duplicate.job.id == repaired.job.id
    assert process_job_count() == 1
  end

  test "a replay after activation still dispatches the same queued Attempt", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("activation-crash")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:ok, claim} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               attempt_snapshot(work_item, bundle, "attempt-activation-crash"),
               enqueue: false
             )

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^work_item.id),
      set: [
        state: "active",
        phase: "preparing_workspace",
        active_attempt_id: "attempt-activation-crash",
        version: work_item.version + 1
      ]
    )

    assert Attempts.get("attempt-activation-crash").state == "queued"

    assert :ok =
             WorkProcess.perform(
               claim.event.event_id,
               work_item.work_item_id,
               work_item.version,
               3_680
             )

    recovered = Attempts.get("attempt-activation-crash")
    assert recovered.state == "running"
    assert recovered.oban_job_id == 3_680
    assert result_count(claim.event.event_id) == 1
    assert WorkItems.get(work_item.work_item_id).active_attempt_id == recovered.attempt_id
  end

  test "invalid planning fails before the atomic claim", %{artifact_dir: artifact_dir} do
    work_item = insert_work!("before-claim")
    _bundle = insert_bundle!(work_item, artifact_dir)

    assert {:error, {:world_snapshot_required, :attempt}} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, %{})

    assert claim_count(work_item) == 0
    assert Repo.aggregate(Attempt, :count) == 0
    assert process_job_count() == 0
  end

  test "waiting work is idle and only its named event can wake it" do
    waiting =
      insert_work!("waiting",
        state: "waiting",
        phase: "awaiting_review",
        waiting_condition: %{kind: "external_event", name: "review_updated"}
      )

    assert {:ok, idle} = WorkProcess.reconcile(waiting.work_item_id, waiting.version, %{})
    assert idle.status == :idle
    assert idle.decision.action == "wait"
    assert process_job_count() == 0
    assert claim_count(waiting) == 0

    wrong_wake = %{
      wake: %{
        kind: "external_event",
        name: "unrelated_event",
        transition: %{state: "ready", phase: "feedback_ready"}
      }
    }

    assert {:error, :wake_condition_mismatch} =
             WorkProcess.reconcile(waiting.work_item_id, waiting.version, wrong_wake)

    matching_wake = %{
      wake: %{
        kind: "external_event",
        name: "review_updated",
        transition: %{
          state: "ready",
          phase: "feedback_ready",
          evidence: %{review_event: %{id: 42}}
        }
      }
    }

    assert {:ok, delivery} =
             WorkProcess.reconcile(waiting.work_item_id, waiting.version, matching_wake)

    assert :ok = WorkCommandJob.perform(delivery.job)
    ready = WorkItems.get(waiting.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "feedback_ready"
  end

  test "timer, Gate resolution, and reconciler evidence are the other typed wake sources" do
    timer =
      insert_work!("timer-wake",
        state: "waiting",
        phase: "awaiting_review",
        waiting_condition: %{kind: "timer", wake_at: "2026-07-29T10:00:00Z"}
      )

    assert {:ok, timer_delivery} =
             WorkProcess.reconcile(timer.work_item_id, timer.version, %{
               now: "2026-07-29T10:00:01Z",
               wake: %{
                 kind: "timer",
                 transition: %{state: "ready", phase: "feedback_ready"}
               }
             })

    assert :ok = WorkCommandJob.perform(timer_delivery.job)

    gate =
      insert_work!("gate-wake",
        state: "waiting",
        phase: "merge_ready",
        waiting_condition: %{kind: "gate", gate_id: "gate-process"}
      )

    assert {:ok, gate_delivery} =
             WorkProcess.reconcile(gate.work_item_id, gate.version, %{
               wake: %{
                 kind: "gate",
                 gate_id: "gate-process",
                 resolution: "approved",
                 transition: %{state: "ready", phase: "merge_ready"}
               }
             })

    assert :ok = WorkCommandJob.perform(gate_delivery.job)

    reconciled =
      insert_work!("reconciler-wake",
        state: "waiting",
        phase: "awaiting_review",
        waiting_condition: %{kind: "reconciler", name: "github_snapshot"}
      )

    assert {:ok, reconciler_delivery} =
             WorkProcess.reconcile(reconciled.work_item_id, reconciled.version, %{
               wake: %{
                 kind: "reconciler",
                 evidence: %{head_sha: "abc123"},
                 transition: %{state: "ready", phase: "conflict_ready"}
               }
             })

    assert :ok = WorkCommandJob.perform(reconciler_delivery.job)
    assert process_job_count() == 3
  end

  test "a terminal executor result proposes but cannot directly apply a transition", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("result", phase: "implementation_ready")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:ok, delivery} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               attempt_snapshot(work_item, bundle, "attempt-result")
             )

    assert :ok = WorkCommandJob.perform(delivery.job)
    active = WorkItems.get(work_item.work_item_id)
    assert active.phase == "implementing"

    assert {:ok, finished} =
             WorkProcess.record_attempt_result("attempt-result", %{
               state: "succeeded",
               usage: %{input_tokens: 10},
               outcome: %{
                 kind: "model_result",
                 proposal: %{
                   state: "ready",
                   phase: "verification_ready",
                   evidence: %{implementation: %{diff_digest: "sha256:abc"}}
                 }
               }
             })

    assert finished.state == "succeeded"
    assert WorkItems.get(work_item.work_item_id).state == "active"

    assert {:ok, transition} =
             WorkProcess.reconcile(work_item.work_item_id, active.version, %{})

    assert transition.decision.action == "transition"
    assert :ok = WorkCommandJob.perform(transition.job)

    ready = WorkItems.get(work_item.work_item_id)
    assert ready.state == "ready"
    assert ready.phase == "verification_ready"
    assert ready.active_attempt_id == nil
  end

  test "an invalid model proposal cannot emit an unknown work-kind phase", %{
    artifact_dir: artifact_dir
  } do
    work_item = insert_work!("invalid-proposal", phase: "implementation_ready")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:ok, delivery} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               attempt_snapshot(work_item, bundle, "attempt-invalid-proposal")
             )

    assert :ok = WorkCommandJob.perform(delivery.job)
    active = WorkItems.get(work_item.work_item_id)

    assert {:ok, _finished} =
             WorkProcess.record_attempt_result("attempt-invalid-proposal", %{
               state: "succeeded",
               usage: %{},
               outcome: %{
                 proposal: %{
                   state: "ready",
                   phase: "invented_by_model",
                   evidence: %{implementation: %{}}
                 }
               }
             })

    assert {:error, {:unknown_phase, "invented_by_model"}} =
             WorkProcess.reconcile(work_item.work_item_id, active.version, %{})

    unchanged = WorkItems.get(work_item.work_item_id)
    assert unchanged.state == "active"
    assert unchanged.phase == "implementing"
    assert process_job_count() == 1
  end

  test "an active item with no execution record is repaired to blocked" do
    active =
      insert_work!("missing-execution",
        state: "active",
        phase: "implementing",
        active_attempt_id: "missing-attempt"
      )

    assert {:ok, repair} = WorkProcess.reconcile(active.work_item_id, active.version, %{})
    assert repair.decision.transition["blocked_reason"]["code"] == "execution_missing"
    assert :ok = WorkCommandJob.perform(repair.job)

    blocked = WorkItems.get(active.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "implementing"

    assert blocked.blocked_reason == %{
             "attempt_id" => "missing-attempt",
             "code" => "execution_missing"
           }
  end

  test "operation decisions preserve actor and transport and never bypass authorization" do
    work_item = insert_work!("operation-contract", phase: "merge_ready")

    assert {:ok, decision} =
             Decision.new(
               %{
                 action: :invoke_operation,
                 operation: %{
                   operation: "fleet.pause_agent",
                   arguments: %{agent_id: "worker"},
                   actor: %{kind: :operator, id: "human"},
                   transport: :worker
                 }
               },
               work_item
             )

    assert decision.operation.actor.kind == :operator
    assert decision.operation.transport == :worker

    snapshot = %{
      operation: %{
        operation: "github.merge_pr",
        arguments: %{
          work_item_id: work_item.work_item_id,
          gate_id: "gate-operation-contract",
          lease_id: "lease-operation-contract",
          repository: "genagent/custode",
          pull_request_number: 372,
          expected_version: work_item.version,
          expected_head_sha: "head-operation-contract",
          policy_version: work_item.policy_ref,
          external_preconditions: %{}
        },
        actor: %{kind: :sub_agent, id: "model"},
        transport: :worker,
        idempotency_key: "unauthorized-operation"
      }
    }

    assert {:error, {:denied, :operator_required}} =
             WorkProcess.reconcile(work_item.work_item_id, work_item.version, snapshot)

    assert Repo.aggregate(OperationCall, :count) == 0
    assert claim_count(work_item) == 0
  end

  test "operation delivery preserves authorization and one logical call on success and failure" do
    success_work = insert_work!("operation-success", phase: "merge_ready")

    success_registry =
      operation_registry(fn _arguments, envelope ->
        send(self(), {:handled, envelope.actor, envelope.transport})
        {:ok, %{merged: true}, [%{type: "merged"}]}
      end)

    assert {:ok, success} =
             WorkProcess.reconcile(
               success_work.work_item_id,
               success_work.version,
               operation_snapshot(success_work, %{kind: :operator, id: "human"}, "success"),
               registry: success_registry,
               correlation_id: "corr-operation",
               causation_id: "cause-operation"
             )

    assert :ok =
             WorkProcess.perform(
               success.event.event_id,
               success_work.work_item_id,
               success_work.version,
               success.job.id,
               registry: success_registry
             )

    assert_receive {:handled, %{kind: :operator, id: "human"}, :worker}

    completion =
      Repo.get_by!(WorkEvent,
        kind: "work.next_action.completed",
        causation_id: success.event.event_id
      )

    Repo.delete!(completion)

    assert :ok =
             WorkProcess.perform(
               success.event.event_id,
               success_work.work_item_id,
               success_work.version,
               success.job.id,
               registry: success_registry
             )

    refute_receive {:handled, _, _}

    assert Repo.aggregate(
             from(call in OperationCall, where: call.operation == "github.merge_pr"),
             :count
           ) ==
             1

    success_call = Repo.get_by!(OperationCall, operation: "github.merge_pr")
    assert success_call.status == "succeeded"
    assert success_call.actor == %{"kind" => "operator", "id" => "human"}
    assert success_call.transport == "worker"
    assert success_call.correlation_id == "corr-operation"
    assert success_call.causation_id == success.event.event_id

    cleanup!()
    failed_work = insert_work!("operation-failure", phase: "merge_ready")
    failure_registry = operation_registry(fn _arguments, _envelope -> {:error, :boom} end)

    assert {:ok, failure} =
             WorkProcess.reconcile(
               failed_work.work_item_id,
               failed_work.version,
               operation_snapshot(failed_work, %{kind: :operator, id: "human"}, "failure"),
               registry: failure_registry
             )

    assert {:discard, {:operation_failed, {:handler_failed, :boom}}} =
             WorkProcess.perform(
               failure.event.event_id,
               failed_work.work_item_id,
               failed_work.version,
               failure.job.id,
               registry: failure_registry
             )

    failed_call = Repo.get_by!(OperationCall, operation: "github.merge_pr")
    assert failed_call.status == "failed"
    assert result_count(failure.event.event_id) == 1

    blocked = WorkItems.get(failed_work.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.blocked_reason["code"] == "operation_failed"
  end

  test "an unauthorized operation is refused before claim or delivery" do
    work_item = insert_work!("operation-denied", phase: "merge_ready")
    registry = operation_registry(fn _arguments, _envelope -> {:ok, %{merged: true}} end)

    assert {:error, {:denied, :operator_required}} =
             WorkProcess.reconcile(
               work_item.work_item_id,
               work_item.version,
               operation_snapshot(work_item, %{kind: :sub_agent, id: "model"}, "denied"),
               registry: registry
             )

    assert Repo.aggregate(OperationCall, :count) == 0
    assert claim_count(work_item) == 0
    assert process_job_count() == 0
  end

  defp insert_work!(suffix, overrides \\ []) do
    mission =
      %{
        mission_id: "mission-process-#{suffix}",
        key: "process:#{suffix}",
        purpose: "Process test #{suffix}",
        lifecycle: "persistent",
        status: "active"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    %{
      work_item_id: "work-process-#{suffix}",
      mission_id: mission.id,
      kind: "github_issue_to_merge",
      workflow_version: 1,
      objective: "Implement #{suffix}",
      acceptance_criteria: %{"tests" => "pass"},
      state: "ready",
      phase: "eligible",
      priority: 1,
      policy_ref: "policy:process",
      source: "process-test",
      external_key: "issue-#{suffix}",
      version: 1
    }
    |> Map.merge(Map.new(overrides))
    |> WorkItem.create_changeset()
    |> Repo.insert!()
    |> Repo.preload(:mission)
  end

  defp insert_bundle!(work_item, artifact_dir) do
    body = %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{"ref" => work_item.policy_ref},
      "recipe" => %{"name" => "issue-work", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => 365, "updated_at" => "2026-07-29"},
      "workspace_revision" => %{"git" => "abc123"}
    }

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(work_item.work_item_id, body, artifact_dir: artifact_dir)

    bundle
  end

  defp attempt_snapshot(work_item, bundle, attempt_id) do
    %{
      attempt: %{
        attempt_id: attempt_id,
        work_item_id: work_item.work_item_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "model",
        provider: "claude",
        profile: "sonnet-low",
        recipe_version: "1",
        expected_work_item_version: work_item.version
      }
    }
  end

  defp operation_snapshot(work_item, actor, suffix) do
    %{
      operation: %{
        operation: "github.merge_pr",
        arguments: %{work_item_id: work_item.work_item_id},
        actor: actor,
        transport: :worker,
        mission_id: work_item.mission.mission_id,
        work_item_id: work_item.work_item_id,
        idempotency_key: "merge-#{suffix}"
      }
    }
  end

  defp operation_registry(handler) do
    {:ok, definition} =
      OperationDefinition.new(
        name: "github.merge_pr",
        input_schema: %{work_item_id: [type: :string, required: true]},
        result_schema: %{merged: [type: :boolean, required: true]},
        classification: :command,
        risk: :external_write,
        required_grants: [:operator],
        authorization: &Authorization.operator/2,
        idempotency: %{required: true, scope: fn envelope -> envelope.work_item_id end},
        effect_preview: fn arguments, _envelope ->
          {:ok, %{effect: "merge", work_item_id: arguments.work_item_id}}
        end,
        handler: handler,
        audit: fn arguments -> "merge #{arguments.work_item_id}" end,
        projection: %{title: "Merge pull request"}
      )

    {:ok, registry} = OperationRegistry.new([definition])
    registry
  end

  defp claim_count(work_item) do
    Repo.aggregate(
      from(event in WorkEvent,
        where: event.work_item_id == ^work_item.id and event.kind == "work.next_action.claimed"
      ),
      :count
    )
  end

  defp result_count(decision_id) do
    Repo.aggregate(
      from(event in WorkEvent,
        where: event.kind == "work.next_action.completed" and event.causation_id == ^decision_id
      ),
      :count
    )
  end

  defp process_job_count do
    Repo.aggregate(
      from(job in Oban.Job, where: job.worker == "Custode.WorkCommandJob"),
      :count
    )
  end

  defp cleanup! do
    Repo.delete_all(from(job in Oban.Job, where: job.worker == "Custode.WorkCommandJob"))
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(WorkEvent)
    Repo.delete_all(WorkGate)
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(OperationCall)
    Repo.delete_all(Custode.RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(Custode.MissionTarget)
    Repo.delete_all(Mission)
  end
end
