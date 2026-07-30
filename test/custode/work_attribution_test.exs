defmodule Custode.WorkAttributionTest do
  use ExUnit.Case, async: false

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundle,
    ContextBundles,
    Mission,
    Repo,
    RoleBinding,
    SpendLedger,
    WorkAttribution,
    WorkEvent,
    WorkItem
  }

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-attribution-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "Attempt-linked charges derive authoritative dimensions and replay idempotently", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_fixture!(artifact_dir)

    options = [
      attempt_id: fixture.attempt.attempt_id,
      ingestion_key: "provider-charge:one",
      model: "claude-sonnet-4-5",
      usage: %{input: 100, output: 20, cache_creation: 5, cache_read: 40}
    ]

    assert :ok = SpendLedger.record("legacy-agent", 0.75, "turn", options)
    assert :ok = SpendLedger.record("legacy-agent", 0.75, "turn", options)
    assert Repo.aggregate(SpendLedger.Entry, :count) == 1

    entry = Repo.one!(SpendLedger.Entry)
    assert entry.attempt_id == fixture.attempt.attempt_id
    assert entry.work_item_id == fixture.work_item.work_item_id
    assert entry.mission_id == fixture.mission.mission_id
    assert entry.role_binding_id == fixture.binding.binding_id
    assert entry.legacy_routine_id == "legacy-agent"
    assert entry.executor_kind == "model"
    assert entry.provider == "claude"
    assert entry.workflow_phase == "implementing"
    assert entry.attribution_key == "attempt:#{fixture.attempt.attempt_id}"
    assert entry.attribution_status == "attempt"

    assert {:error, {:ingestion_conflict, "provider-charge:one"}} =
             SpendLedger.record("legacy-agent", 0.76, "turn", options)

    assert {:error,
            {:attribution_mismatch,
             %{field: :work_item_id, expected: expected, observed: "wrong-work"}}} =
             SpendLedger.record("legacy-agent", 1.0, "turn",
               attempt_id: fixture.attempt.attempt_id,
               work_item_id: "wrong-work"
             )

    assert expected == fixture.work_item.work_item_id

    assert {:error, {:unknown_attempt, "missing-attempt"}} =
             SpendLedger.record("legacy-agent", 1.0, "turn", attempt_id: "missing-attempt")

    assert Repo.aggregate(SpendLedger.Entry, :count) == 1
  end

  test "telemetry replay uses the physical Oban delivery as its ingestion key", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_fixture!(artifact_dir)

    meta = %{
      job: %{
        id: 42,
        attempt: 3,
        meta: %{
          "agent_id" => "legacy-agent",
          "attempt_id" => fixture.attempt.attempt_id,
          "work_item_id" => fixture.work_item.work_item_id,
          "mission_id" => fixture.mission.mission_id
        }
      },
      args: %{"model" => "claude-sonnet-4-5"}
    }

    for _replay <- 1..2 do
      assert :ok =
               SpendLedger.handle_event(
                 [:oban_claude, :run, :stop],
                 %{cost_usd: 0.75},
                 meta,
                 nil
               )
    end

    assert [entry] = Repo.all(SpendLedger.Entry)
    assert entry.ingestion_key == "oban_claude:job:42:attempt:3:stop"
    assert entry.attempt_id == fixture.attempt.attempt_id
  end

  test "Mission, WorkItem, Attempt, and role summaries reconcile without double counting", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_fixture!(artifact_dir)

    assert {:ok, first} =
             Attempts.finish(fixture.attempt.attempt_id, %{
               state: "partial",
               usage: %{cost_usd: 0.75, duration_ms: 1_000, num_turns: 2},
               outcome: %{kind: "verification", result: "repair_needed"}
             })

    assert :ok =
             SpendLedger.record("legacy-agent", 0.75, "turn",
               attempt_id: first.attempt_id,
               ingestion_key: "charge:first",
               model: "claude-sonnet-4-5"
             )

    assert {:ok, {:created, repair}} =
             Attempts.repair(
               first.attempt_id,
               attempt_attrs(fixture.work_item, fixture.bundle,
                 attempt_id: "attempt-repair",
                 role_binding_id: fixture.binding.binding_id,
                 provenance: %{"active_phase" => "repairing"}
               )
             )

    assert {:ok, repair} =
             Attempts.finish(repair.attempt_id, %{
               state: "succeeded",
               usage: %{cost_usd: 0.25, duration_ms: 300, commands: 2, num_turns: 1},
               outcome: %{kind: "semantic_repair", result: "passed"}
             })

    assert :ok =
             SpendLedger.record("legacy-agent", 0.25, "turn",
               attempt_id: repair.attempt_id,
               ingestion_key: "charge:repair",
               model: "claude-sonnet-4-5"
             )

    complete_work!(fixture.work_item, repair)
    artifact = insert_evidence!(fixture.work_item, repair)
    event = insert_event!(fixture.work_item, "completed", %{artifact_id: artifact.artifact_id})

    assert {:ok, attempt_summary} = WorkAttribution.attempt_summary(first.attempt_id)
    assert attempt_summary.usage.attributed_cost_usd == 0.75
    assert attempt_summary.usage.logical_attempt_usage.reported_cost_usd == 0.75
    assert attempt_summary.usage.reconciliation.status == "reconciled"

    assert {:ok, work_summary} =
             WorkAttribution.work_item_summary(fixture.work_item.work_item_id)

    assert {:ok, mission_summary} =
             WorkAttribution.mission_summary(fixture.mission.mission_id)

    assert {:ok, role_summary} =
             WorkAttribution.role_summary(fixture.binding.binding_id)

    for summary <- [work_summary, mission_summary, role_summary] do
      assert summary.usage.attributed_cost_usd == 1.0
      assert summary.usage.physical_charges.cost_usd == 1.0
      assert summary.usage.physical_charges.charges == 2
      assert summary.usage.logical_attempt_usage.reported_cost_usd == 1.0
      assert summary.usage.logical_attempt_usage.attempts == 2
      assert summary.usage.reconciliation.status == "reconciled"
      assert summary.repair_effort.attempts == 1
      assert summary.repair_effort.attributed_cost_usd == 0.25
      assert summary.repair_effort.duration_ms == 300
      assert summary.dimensions.providers == %{"claude" => 2}
      assert summary.dimensions.models == %{"claude-sonnet-4-5" => 2}
      assert summary.dimensions.role_binding_ids == %{fixture.binding.binding_id => 2}
      assert summary.relationships.limit == 25
    end

    assert mission_summary.usage == work_summary.usage
    assert work_summary.relationships.attempt_ids == [first.attempt_id, repair.attempt_id]

    assert [disposition] = work_summary.outcomes.dispositions
    assert disposition.state == "completed"
    assert disposition.evidence.last_event_id == event.event_id
    assert artifact.artifact_id in disposition.evidence.artifact_ids
  end

  test "outcomes stay distinct and unattributed history stays visible and bounded", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_fixture!(artifact_dir)
    complete_work!(fixture.work_item, fixture.attempt)
    completed_event = insert_event!(fixture.work_item, "completed", %{result: "merged"})

    cancelled = insert_work!(fixture.mission, "cancelled", "cancelled")
    cancel_work!(cancelled)
    insert_event!(cancelled, "cancelled", %{reason: "superseded"})

    blocked = insert_work!(fixture.mission, "blocked", "blocked")
    block_work!(blocked)
    insert_event!(blocked, "blocked", %{gate: "operator"})

    assert :ok =
             SpendLedger.record("old-agent", 2.0, "turn",
               ingestion_key: "legacy:one",
               model: "legacy-model"
             )

    Repo.insert!(
      SpendLedger.Entry.changeset(%{
        agent_id: "old-agent",
        cost_usd: 1.0,
        outcome: "failed",
        attempt_id: "deleted-attempt",
        attribution_key: "unknown_attempt:deleted-attempt",
        attribution_status: "unknown_attempt"
      })
    )

    assert {:ok, mission_summary} =
             WorkAttribution.mission_summary(fixture.mission.mission_id, limit: 2)

    assert mission_summary.outcomes.work_item_states == %{
             "blocked" => 1,
             "cancelled" => 1,
             "completed" => 1
           }

    assert mission_summary.outcomes.dispositions_truncated
    assert mission_summary.outcomes.disposition_limit == 2

    assert Enum.any?(
             mission_summary.outcomes.dispositions,
             &(&1.work_item_id == blocked.work_item_id and &1.blocked_reason["kind"] == "gate")
           )

    assert {:ok, completed_summary} =
             WorkAttribution.work_item_summary(fixture.work_item.work_item_id)

    assert hd(completed_summary.outcomes.dispositions).evidence.last_event_id ==
             completed_event.event_id

    assert mission_summary.usage.attributed_cost_usd == 0.0

    assert {:ok, unattributed} = WorkAttribution.unattributed_summary(limit: 1)
    assert unattributed.usage.cost_usd == 3.0
    assert unattributed.usage.charges == 2
    assert unattributed.by_status["legacy_unattributed"].cost_usd == 2.0
    assert unattributed.by_status["unknown_attempt"].cost_usd == 1.0
    assert length(unattributed.recent) == 1
    assert unattributed.recent_truncated

    assert {:error, {:invalid_limit, 101}} =
             WorkAttribution.mission_summary(fixture.mission.mission_id, limit: 101)

    assert {:error, {:unknown_attempt, "missing"}} =
             WorkAttribution.attempt_summary("missing")
  end

  defp insert_fixture!(artifact_dir) do
    mission = insert_mission!()
    work_item = insert_work!(mission, "primary", "ready")
    binding = insert_binding!(mission)

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(work_item.work_item_id, context_body(work_item),
               artifact_dir: artifact_dir
             )

    assert {:ok, {:created, attempt}} =
             Attempts.create(
               attempt_attrs(work_item, bundle,
                 attempt_id: "attempt-primary",
                 role_binding_id: binding.binding_id,
                 provenance: %{"active_phase" => "implementing"}
               )
             )

    active =
      work_item
      |> Ecto.Changeset.change(
        state: "active",
        phase: "implementing",
        active_attempt_id: attempt.attempt_id
      )
      |> Repo.update!()
      |> Repo.preload(:mission)

    %{
      mission: mission,
      work_item: active,
      binding: binding,
      bundle: bundle,
      attempt: attempt
    }
  end

  defp insert_mission! do
    %{
      mission_id: "mission-attribution",
      key: "test:attribution",
      purpose: "Test cost and outcome attribution",
      lifecycle: "persistent",
      status: "active"
    }
    |> Mission.create_changeset()
    |> Repo.insert!()
  end

  defp insert_work!(mission, suffix, state) do
    %{
      work_item_id: "work-#{suffix}",
      mission_id: mission.id,
      kind: "github_issue_delivery",
      workflow_version: 1,
      objective: "Implement #{suffix}",
      acceptance_criteria: %{"tests" => "pass"},
      state: state,
      phase: if(state == "ready", do: "eligible", else: state),
      priority: 1,
      policy_ref: "policy:default",
      source: "test",
      external_key: "issue-#{suffix}",
      version: 1
    }
    |> WorkItem.create_changeset()
    |> Repo.insert!()
    |> Repo.preload(:mission)
  end

  defp insert_binding!(mission) do
    %{
      binding_id: "binding-implementer",
      mission_id: mission.id,
      key: "implementer",
      template_key: "implementer",
      template_version: "1",
      authority_source: "legacy_routine",
      legacy_routine_id: "legacy-agent",
      scoped_overrides: %{},
      grants: %{},
      lifecycle: "active",
      provenance: %{}
    }
    |> RoleBinding.create_changeset()
    |> Repo.insert!()
  end

  defp attempt_attrs(work_item, bundle, overrides) do
    Map.merge(
      %{
        attempt_id: Ecto.UUID.generate(),
        work_item_id: work_item.work_item_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "model",
        provider: "claude",
        profile: "sonnet-low",
        recipe_version: "1",
        expected_work_item_version: work_item.version
      },
      Map.new(overrides)
    )
  end

  defp context_body(work_item) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{"ref" => work_item.policy_ref},
      "recipe" => %{"name" => "issue-work", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => 375, "updated_at" => "2026-07-29"},
      "workspace_revision" => %{"git" => "abc123"}
    }
  end

  defp complete_work!(work_item, attempt) do
    work_item
    |> Ecto.Changeset.change(
      state: "completed",
      phase: "done",
      active_attempt_id: nil,
      outcome: %{kind: "github_pull_request_merged", merge_commit_sha: "abc123"},
      completed_at: DateTime.utc_now(),
      version: work_item.version + 1
    )
    |> Repo.update!()

    attempt
  end

  defp cancel_work!(work_item) do
    work_item
    |> Ecto.Changeset.change(
      phase: "done",
      outcome: %{kind: "cancelled", reason: "superseded"},
      cancelled_at: DateTime.utc_now(),
      version: work_item.version + 1
    )
    |> Repo.update!()
  end

  defp block_work!(work_item) do
    work_item
    |> Ecto.Changeset.change(
      blocked_reason: %{kind: "gate", gate: "operator"},
      version: work_item.version + 1
    )
    |> Repo.update!()
  end

  defp insert_evidence!(work_item, attempt) do
    assert {:ok, artifact} =
             Artifacts.create(%{
               artifact_id: "artifact-attribution",
               work_item_id: work_item.work_item_id,
               producer_attempt_id: attempt.attempt_id,
               kind: "pull_request",
               external_identity: "github:genagent/custode:pull:1",
               media_type: "application/json",
               location: "github://genagent/custode/pull/1",
               size_bytes: 0,
               provenance: %{source: "github"},
               retention: %{policy: "mission"}
             })

    artifact
  end

  defp insert_event!(work_item, state, evidence) do
    current = Repo.get!(WorkItem, work_item.id)

    %{
      event_id: Ecto.UUID.generate(),
      work_item_id: current.id,
      mission_id: current.mission_id,
      kind: "work_item.transitioned",
      actor: %{"kind" => "system", "id" => "attribution-test"},
      operation: "work_item.transition",
      before_state: "active",
      before_phase: "implementing",
      after_state: state,
      after_phase: current.phase,
      before_version: max(current.version - 1, 1),
      work_item_version: current.version,
      evidence: evidence
    }
    |> WorkEvent.create_changeset()
    |> Repo.insert!()
  end

  defp cleanup! do
    Repo.query!("DELETE FROM workflow_node_results")
    Repo.query!("DELETE FROM workflow_runs")
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(Custode.MissionTarget)
    Repo.delete_all(Custode.OperationCall)
    Repo.delete_all(Mission)
  end
end
