defmodule Custode.WorkReadModelsTest do
  use ExUnit.Case, async: false

  alias Custode.TestHelpers

  alias Custode.{
    Artifacts,
    Attempts,
    ContextBundles,
    LegacyRoutineMissionMapping,
    Mission,
    Repo,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems,
    WorkReadModels
  }

  alias Custode.Operations.Missions, as: MissionOperations
  alias Custode.Operations.WorkItems, as: WorkOperations

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-read-models-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "list and detail contracts expose generic work truth and traversal IDs", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_projection_fixture!(artifact_dir)

    assert {:ok, mission_page} = WorkReadModels.list_missions(limit: 10)
    assert mission_page.page.order == ["inserted_at:asc", "mission_id:asc"]
    assert mission_page.page.has_more == false
    assert mission_page.page.next_cursor == nil

    assert [mission_summary] = mission_page.items
    assert mission_summary.contract == "custode.mission.summary.v1"
    assert mission_summary.mission_id == fixture.mission.mission_id
    assert mission_summary.work.by_state["waiting"] == 1
    assert mission_summary.last_transition.after.state == "waiting"

    assert mission_summary.compatibility == %{
             authoritative_store: "missions",
             legacy_projection: %{
               present: true,
               read_only: true,
               projected_fields: ~w(
                   key
                   purpose
                   lifecycle
                   targets
                   policy_ref
                   budget_ref
                   context_ref
                   retention_seconds
                   metadata
                 ),
               mappings: [
                 %{
                   mapping_id: "mapping-read-model",
                   legacy_routine_id: "legacy-custode",
                   strategy: "repository",
                   status: "active"
                 }
               ]
             }
           }

    assert {:ok, work_page} =
             WorkReadModels.list_work_items(
               mission_id: fixture.mission.mission_id,
               limit: 10
             )

    assert [work_summary] = work_page.items
    assert work_summary.contract == "custode.work_item.summary.v1"
    assert work_summary.state == "waiting"
    assert work_summary.phase == "eligible"
    assert work_summary.version == 4
    assert work_summary.kind == "github_issue_to_merge"
    assert work_summary.workflow_version == 1

    assert work_summary.target == %{
             source: "github",
             external_key: "github:123:issue:373",
             mission_targets: [
               %{
                 kind: "github_repository",
                 external_id: "123",
                 display_name: "genagent/custode",
                 metadata: %{}
               }
             ]
           }

    assert work_summary.current_attempt == %{
             attempt_id: fixture.attempt.attempt_id,
             state: "succeeded",
             active: false,
             executor_kind: "model",
             provider: "claude",
             profile: "sonnet-low",
             recipe_version: "1",
             expected_work_item_version: 3,
             started_at: nil,
             finished_at: DateTime.to_iso8601(fixture.attempt.finished_at)
           }

    assert [%{gate_id: "gate-read-model", status: "open"}] = work_summary.open_gates

    assert Enum.map(work_summary.relevant_artifacts, & &1.artifact_id) ==
             [fixture.bundle.artifact.artifact_id, fixture.artifact.artifact_id]

    assert work_summary.last_transition.after == %{
             state: "waiting",
             phase: "eligible",
             version: 4
           }

    assert work_summary.last_transition.correlation_id == "corr-waiting"
    assert work_summary.last_transition.causation_id == "cause-waiting"

    assert {:ok, mission_detail} =
             WorkReadModels.get_mission(fixture.mission.mission_id)

    assert mission_detail.contract == "custode.mission.detail.v1"
    assert fixture.work_item.work_item_id in mission_detail.relationships.work_item_ids
    assert fixture.attempt.attempt_id in mission_detail.relationships.attempt_ids
    assert "gate-read-model" in mission_detail.relationships.gate_ids
    assert fixture.artifact.artifact_id in mission_detail.relationships.artifact_ids
    assert fixture.waiting_event.event_id in mission_detail.relationships.event_ids

    assert {:ok, work_detail} =
             WorkReadModels.get_work_item(fixture.work_item.work_item_id)

    assert work_detail.contract == "custode.work_item.detail.v1"
    assert work_detail.current_attempt.attempt_id == fixture.attempt.attempt_id
    assert work_detail.current_attempt.outcome == %{"kind" => "implementation"}
    assert [%{gate_id: "gate-read-model"}] = work_detail.open_gates
    assert fixture.attempt.attempt_id in work_detail.relationships.attempt_ids
    assert fixture.waiting_event.event_id in work_detail.relationships.event_ids

    assert fixture.waiting_event.operation_call_id in work_detail.relationships.operation_call_ids

    assert work_detail.compatibility.legacy_mission_scope.read_only
    assert work_detail.state != work_detail.phase
  end

  test "projections rebuild from authoritative rows and events without becoming writable", %{
    artifact_dir: artifact_dir
  } do
    fixture = insert_projection_fixture!(artifact_dir)

    assert {:ok, original} =
             WorkReadModels.get_work_item(fixture.work_item.work_item_id)

    changed_copy =
      original
      |> Map.put(:state, "completed")
      |> put_in([:compatibility, :legacy_mission_scope, :read_only], false)

    assert changed_copy.state == "completed"
    assert {:ok, ^original} = WorkReadModels.rebuild_work_item(fixture.work_item.work_item_id)

    current = WorkItems.get(fixture.work_item.work_item_id)

    assert {:ok, response} =
             WorkOperations.Transition.dispatch(
               current.work_item_id,
               %{
                 expected_version: current.version,
                 state: "blocked",
                 phase: current.phase,
                 blocked_reason: %{kind: "operator_input", detail: "needs a decision"}
               },
               invocation("read-model-blocked",
                 correlation_id: "corr-blocked",
                 causation_id: "cause-blocked"
               )
             )

    assert response.result.work_item.state == "blocked"

    assert {:ok, rebuilt} =
             WorkReadModels.rebuild_work_item(fixture.work_item.work_item_id)

    assert original.state == "waiting"
    assert rebuilt.state == "blocked"
    assert rebuilt.phase == "eligible"
    assert rebuilt.version == original.version + 1
    assert rebuilt.last_transition.after.state == "blocked"
    assert rebuilt.last_transition.correlation_id == "corr-blocked"
    assert rebuilt.last_transition.causation_id == "cause-blocked"

    assert {:ok, mission_before} =
             WorkReadModels.get_mission(fixture.mission.mission_id)

    assert {:ok, ^mission_before} =
             WorkReadModels.rebuild_mission(fixture.mission.mission_id)
  end

  test "opaque keyset cursors paginate deterministically and remain scope-bound" do
    inserted_at = ~U[2026-07-29 12:00:00.000000Z]

    for id <- ~w(mission-c mission-a mission-b) do
      insert_mission!(id, inserted_at)
    end

    assert {:ok, first} = WorkReadModels.list_missions(limit: 2)
    assert Enum.map(first.items, & &1.mission_id) == ~w(mission-a mission-b)
    assert first.page.has_more
    assert is_binary(first.page.next_cursor)

    assert {:ok, second} =
             WorkReadModels.list_missions(limit: 2, after: first.page.next_cursor)

    assert Enum.map(second.items, & &1.mission_id) == ["mission-c"]
    refute second.page.has_more
    assert second.page.next_cursor == nil

    mission = Repo.get_by!(Mission, mission_id: "mission-a")

    for id <- ~w(work-c work-a work-b) do
      insert_work_item!(mission, id, inserted_at)
    end

    assert {:ok, work_first} =
             WorkReadModels.list_work_items(mission_id: "mission-a", limit: 2)

    assert Enum.map(work_first.items, & &1.work_item_id) == ~w(work-a work-b)

    assert {:ok, work_second} =
             WorkReadModels.list_work_items(
               mission_id: "mission-a",
               limit: 2,
               after: work_first.page.next_cursor
             )

    assert Enum.map(work_second.items, & &1.work_item_id) == ["work-c"]

    assert {:error, {:invalid_cursor, _cursor}} =
             WorkReadModels.list_work_items(
               mission_id: "mission-b",
               after: work_first.page.next_cursor
             )

    assert {:error, {:invalid_cursor, "not-a-cursor"}} =
             WorkReadModels.list_missions(after: "not-a-cursor")

    assert {:error, {:invalid_limit, 101}} = WorkReadModels.list_missions(limit: 101)
  end

  test "missing detail records return stable typed errors" do
    assert {:ok, %{items: [], page: %{has_more: false, next_cursor: nil}}} =
             WorkReadModels.list_missions(%{"limit" => 5})

    assert {:ok, %{items: [], page: %{has_more: false, next_cursor: nil}}} =
             WorkReadModels.list_work_items(%{"limit" => 5})

    assert {:error, {:unknown_mission, "missing"}} = WorkReadModels.get_mission("missing")

    assert {:error, {:unknown_work_item, "missing"}} =
             WorkReadModels.get_work_item("missing")
  end

  defp insert_projection_fixture!(artifact_dir) do
    mission = create_mission!()
    insert_legacy_mapping!(mission)
    work_item = create_work_item!(mission)
    ready = advance_to_ready!(work_item)

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(ready.work_item_id, context_body(ready),
               artifact_dir: artifact_dir
             )

    assert {:ok, {:created, attempt}} =
             Attempts.create(%{
               attempt_id: "attempt-read-model",
               work_item_id: ready.work_item_id,
               context_bundle_id: bundle.context_bundle_id,
               executor_kind: "model",
               provider: "claude",
               profile: "sonnet-low",
               recipe_version: "1",
               expected_work_item_version: ready.version
             })

    assert {:ok, attempt} =
             Attempts.finish(attempt.attempt_id, %{
               state: "succeeded",
               usage: %{input_tokens: 10, output_tokens: 4},
               outcome: %{kind: "implementation"}
             })

    assert {:ok, artifact} =
             Artifacts.create(%{
               artifact_id: "artifact-read-model",
               work_item_id: ready.work_item_id,
               producer_attempt_id: attempt.attempt_id,
               kind: "external_snapshot",
               external_identity: "github:123:issue:373:revision:1",
               media_type: "application/json",
               location: "github://genagent/custode/issues/373",
               size_bytes: 0,
               provenance: %{source: "github"},
               retention: %{policy: "mission"}
             })

    assert {:ok, waiting_response} =
             WorkOperations.Transition.dispatch(
               ready.work_item_id,
               %{
                 expected_version: ready.version,
                 state: "waiting",
                 phase: ready.phase,
                 waiting_condition: %{kind: "gate", gate_id: "gate-read-model"}
               },
               invocation("read-model-waiting",
                 correlation_id: "corr-waiting",
                 causation_id: "cause-waiting"
               )
             )

    waiting = WorkItems.get(ready.work_item_id)
    waiting_event = Repo.get_by!(WorkEvent, event_id: waiting_response.result.event.event_id)
    insert_gate!(waiting, attempt)

    %{
      mission: mission,
      work_item: waiting,
      bundle: bundle,
      attempt: attempt,
      artifact: artifact,
      waiting_event: waiting_event
    }
  end

  defp create_mission! do
    assert {:ok, response} =
             MissionOperations.Create.dispatch(
               %{
                 key: "github:repository:123",
                 purpose: "Operate genagent/custode",
                 lifecycle: "persistent",
                 policy_ref: "policy-v1",
                 targets: [
                   %{
                     kind: "github_repository",
                     external_id: "123",
                     display_name: "genagent/custode"
                   }
                 ]
               },
               invocation("read-model-mission")
             )

    Custode.Missions.get(response.result.mission.mission_id)
  end

  defp create_work_item!(mission) do
    assert {:ok, response} =
             WorkOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 kind: "github_issue_to_merge",
                 workflow_version: 1,
                 objective: "Implement issue 373",
                 acceptance_criteria: %{tests: "pass"},
                 phase: "discovered",
                 priority: 2,
                 source: "github",
                 external_key: "github:123:issue:373"
               },
               invocation("read-model-work")
             )

    WorkItems.get(response.result.work_item.work_item_id)
  end

  defp advance_to_ready!(work_item) do
    assert {:ok, _response} =
             WorkOperations.Transition.dispatch(
               work_item.work_item_id,
               %{
                 expected_version: work_item.version,
                 state: "proposed",
                 phase: "triaging",
                 evidence: %{source_snapshot: %{revision: "issue-r1"}}
               },
               invocation("read-model-triaging")
             )

    triaging = WorkItems.get(work_item.work_item_id)

    assert {:ok, _response} =
             WorkOperations.Transition.dispatch(
               triaging.work_item_id,
               %{
                 expected_version: triaging.version,
                 state: "ready",
                 phase: "eligible",
                 evidence: %{eligibility: %{decision: "eligible"}}
               },
               invocation("read-model-eligible")
             )

    WorkItems.get(work_item.work_item_id)
  end

  defp insert_gate!(work_item, attempt) do
    %{
      gate_id: "gate-read-model",
      mission_id: work_item.mission_id,
      work_item_id: work_item.id,
      attempt_id: attempt.id,
      subject_kind: "operation_call",
      operation: "github.merge_pr",
      arguments: %{"work_item_id" => work_item.work_item_id},
      preview: %{"effect" => "merge"},
      requester: %{"actor" => %{"kind" => "system", "id" => "process-manager"}},
      status: "open",
      work_item_version: work_item.version,
      policy_version: "policy-v1",
      grant_decision: %{"decision" => "allowed"},
      external_preconditions: %{"head_sha" => "abc123"},
      definition_fingerprint: "definition-v1",
      operation_idempotency_key: "gate-read-model:merge",
      correlation_id: "corr-gate",
      causation_id: "cause-gate"
    }
    |> WorkGate.create_changeset()
    |> Repo.insert!()
  end

  defp insert_legacy_mapping!(mission) do
    observation = %{"legacy_routine_id" => "legacy-custode", "source" => %{"kind" => "test"}}

    %{
      mapping_id: "mapping-read-model",
      legacy_routine_id: "legacy-custode",
      mission_id: mission.id,
      strategy: "repository",
      mapping_identity: "github_repository:123",
      status: "active",
      source_snapshot: observation,
      last_observed_snapshot: observation,
      last_observed_fingerprint: "fingerprint-read-model"
    }
    |> LegacyRoutineMissionMapping.create_changeset()
    |> Repo.insert!()
  end

  defp context_body(work_item) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{"ref" => work_item.policy_ref},
      "recipe" => %{"name" => "issue-work", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => 373, "updated_at" => "2026-07-29"},
      "workspace_revision" => %{"git" => "abc123"}
    }
  end

  defp insert_mission!(mission_id, inserted_at) do
    %{
      mission_id: mission_id,
      key: "test:#{mission_id}",
      purpose: "Test #{mission_id}",
      lifecycle: "persistent",
      status: "active"
    }
    |> Mission.create_changeset()
    |> Repo.insert!()
    |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
    |> Repo.update!()
  end

  defp insert_work_item!(mission, work_item_id, inserted_at) do
    %{
      work_item_id: work_item_id,
      mission_id: mission.id,
      kind: "github_issue_to_merge",
      workflow_version: 1,
      objective: "Test #{work_item_id}",
      acceptance_criteria: %{"tests" => "pass"},
      state: "proposed",
      phase: "discovered",
      priority: 0,
      source: "pagination",
      external_key: "pagination:#{work_item_id}",
      version: 1
    }
    |> WorkItem.create_changeset()
    |> Repo.insert!()
    |> Ecto.Changeset.change(inserted_at: inserted_at, updated_at: inserted_at)
    |> Repo.update!()
  end

  defp invocation(idempotency_key, extra \\ []) do
    [
      actor: %{kind: :operator, id: "human"},
      transport: :worker,
      idempotency_key: idempotency_key
    ]
    |> Keyword.merge(extra)
  end

  defp cleanup! do
    TestHelpers.truncate_work!()
  end
end
