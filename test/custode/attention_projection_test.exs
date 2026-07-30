defmodule Custode.AttentionProjectionTest do
  use ExUnit.Case, async: false

  alias Custode.{
    Artifact,
    Asks,
    Attempt,
    Attention,
    ContextBundle,
    Gates,
    LegacyRoutineMissionMapping,
    Mission,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding,
    WorkEvent,
    WorkGate,
    WorkItem
  }

  @now ~U[2026-07-30 12:00:00.000000Z]

  setup do
    cleanup!()

    on_exit(&cleanup!/0)

    mission = insert_mission!("mission-attention")
    work_item = insert_work_item!(mission, "work-attention")

    %{mission: mission, work_item: work_item}
  end

  test "open work Gates share the typed work subject contract", %{
    mission: mission,
    work_item: work_item
  } do
    raised_at = DateTime.add(@now, -3600, :second)
    gate = insert_work_gate!(mission, work_item, "gate-attention", raised_at)

    assert {:ok, %{items: [item], page: page}} =
             Attention.list(include_legacy: false, now: @now)

    assert item.contract == "custode.attention.item.v1"
    assert item.attention_key == "work_gate:#{gate.gate_id}"

    assert item.subject == %{
             kind: "work_item",
             id: work_item.work_item_id,
             mission_id: mission.mission_id,
             work_item_id: work_item.work_item_id
           }

    assert item.mission_id == mission.mission_id
    assert item.work_item_id == work_item.work_item_id
    assert item.reason.kind == "gate.open"
    assert item.reason.detail == "Approve the exact merge"
    assert item.severity == "high"
    assert item.age_seconds == 3600
    assert item.owner == %{kind: "operator", id: "operator"}

    assert item.source == %{
             kind: "work_gate",
             id: gate.gate_id,
             status: "open",
             operation: "github.merge_pr"
           }

    assert item.compatibility == %{legacy: false, authoritative_store: "work_gate"}
    assert page.order == ["severity:desc", "raised_at:asc", "attention_key:asc"]
  end

  test "Gate Attention resolves from source state and a later Gate reopens once", %{
    mission: mission,
    work_item: work_item
  } do
    gate = insert_work_gate!(mission, work_item, "gate-first", DateTime.add(@now, -60, :second))

    assert {:ok, %{items: [first]}} =
             Attention.list(include_legacy: false, now: @now)

    assert first.attention_key == "work_gate:gate-first"

    assert {:ok, %{items: [same]}} =
             Attention.list(include_legacy: false, now: @now)

    assert same.attention_key == first.attention_key

    gate
    |> Ecto.Changeset.change(
      status: "approved",
      resolution: %{"decision" => "approved"},
      resolver: %{"kind" => "operator", "id" => "operator"},
      resolved_at: @now
    )
    |> Repo.update!()

    assert {:ok, %{items: []}} =
             Attention.list(include_legacy: false, now: @now)

    _reopened =
      insert_work_gate!(
        mission,
        work_item,
        "gate-reopened",
        DateTime.add(@now, -30, :second)
      )

    assert {:ok, %{items: [reopened]}} =
             Attention.list(include_legacy: false, now: @now)

    assert reopened.attention_key == "work_gate:gate-reopened"
  end

  test "blocked work specializes repair exhaustion and stale external state", %{
    mission: mission,
    work_item: work_item
  } do
    work_item =
      update_work_item!(work_item,
        state: "blocked",
        blocked_reason: %{
          "code" => "repair_policy_exhausted",
          "detail" => "no repairs remain",
          "limit" => %{"name" => "repairs"}
        },
        updated_at: DateTime.add(@now, -120, :second)
      )

    transition =
      insert_work_event!(
        mission,
        work_item,
        "event-blocked",
        DateTime.add(@now, -600, :second)
      )

    assert {:ok, %{items: [exhausted]}} =
             Attention.list(include_legacy: false, now: @now)

    assert exhausted.attention_key == "work_item:#{work_item.work_item_id}:blocked"
    assert exhausted.reason.kind == "repair_policy.exhausted"
    assert exhausted.reason.detail == "no repairs remain"
    assert exhausted.reason.evidence["limit"]["name"] == "repairs"
    assert exhausted.age_seconds == 600
    assert exhausted.source.transition_event_id == transition.event_id

    work_item =
      update_work_item!(work_item,
        state: "ready",
        blocked_reason: nil,
        updated_at: DateTime.add(@now, -60, :second)
      )

    assert {:ok, %{items: []}} =
             Attention.list(include_legacy: false, now: @now)

    _reblocked =
      update_work_item!(work_item,
        state: "blocked",
        blocked_reason: %{"code" => "publication_stale"},
        updated_at: DateTime.add(@now, -30, :second)
      )

    assert {:ok, %{items: [stale]}} =
             Attention.list(include_legacy: false, now: @now)

    assert stale.attention_key == "work_item:#{work_item.work_item_id}:blocked"
    assert stale.reason.kind == "external_state.stale"
  end

  test "the latest OperationCall outcome determines Mission and WorkItem Attention", %{
    mission: mission,
    work_item: work_item
  } do
    failed_at = DateTime.add(@now, -120, :second)

    _failed =
      insert_call!(
        "call-failed",
        "missions.update",
        "failed",
        failed_at,
        mission_id: mission.mission_id,
        error: %{"kind" => "handler_failed", "message" => "provider offline"}
      )

    assert {:ok, %{items: [failed]}} =
             Attention.list(include_legacy: false, now: @now)

    assert failed.subject == %{
             kind: "mission",
             id: mission.mission_id,
             mission_id: mission.mission_id,
             work_item_id: nil
           }

    assert failed.reason.kind == "operation.failed"
    assert failed.reason.detail == "provider offline"
    assert failed.source.id == "call-failed"

    _succeeded =
      insert_call!(
        "call-succeeded",
        "missions.update",
        "succeeded",
        DateTime.add(@now, -60, :second),
        mission_id: mission.mission_id
      )

    assert {:ok, %{items: []}} =
             Attention.list(include_legacy: false, now: @now)

    _stale =
      insert_call!(
        "call-stale",
        "github.merge_pr",
        "stale",
        DateTime.add(@now, -30, :second),
        mission_id: mission.mission_id,
        work_item_id: work_item.work_item_id,
        error: %{"kind" => "stale", "message" => "head revision changed"}
      )

    assert {:ok, %{items: [stale]}} =
             Attention.list(include_legacy: false, now: @now)

    assert stale.subject.kind == "work_item"
    assert stale.subject.id == work_item.work_item_id
    assert stale.reason.kind == "external_state.stale"
    assert stale.reason.detail == "head revision changed"

    _blocked =
      update_work_item!(work_item,
        state: "blocked",
        blocked_reason: %{"code" => "publication_stale"},
        updated_at: DateTime.add(@now, -15, :second)
      )

    assert {:ok, %{items: [deduplicated]}} =
             Attention.list(include_legacy: false, now: @now)

    assert deduplicated.attention_key == "work_item:#{work_item.work_item_id}:blocked"
    assert deduplicated.reason.kind == "external_state.stale"
  end

  test "open legacy asks and gates have explicit compatibility projections" do
    ask =
      %Asks.Ask{
        agent_id: "legacy-asker",
        question: "Which branch?",
        status: "open"
      }
      |> put_timestamps(DateTime.add(@now, -120, :second))
      |> Repo.insert!()

    gate =
      %Gates.Gate{
        agent_id: "legacy-gated",
        kind: "approval",
        action_id: "action-1",
        detail: "Publish the draft",
        status: "open"
      }
      |> put_timestamps(DateTime.add(@now, -60, :second))
      |> Repo.insert!()

    assert {:ok, %{items: items}} = Attention.list(now: @now)

    assert Enum.map(items, & &1.attention_key) ==
             ["legacy_ask:#{ask.id}", "legacy_gate:#{gate.id}"]

    for item <- items do
      assert item.subject.kind == "legacy_agent"
      assert item.compatibility.legacy
      assert item.compatibility.authoritative_store in ["asks", "gates"]
    end

    ask |> Ecto.Changeset.change(status: "answered", answered_at: @now) |> Repo.update!()
    gate |> Ecto.Changeset.change(status: "resolved") |> Repo.update!()

    assert {:ok, %{items: []}} = Attention.list(now: @now)
  end

  test "pagination and filters are deterministic and scope-bound", %{
    mission: mission,
    work_item: work_item
  } do
    second = insert_work_item!(mission, "work-second")
    other_mission = insert_mission!("mission-other")
    other = insert_work_item!(other_mission, "work-other")

    update_work_item!(work_item,
      state: "blocked",
      blocked_reason: %{"code" => "first"},
      updated_at: DateTime.add(@now, -180, :second)
    )

    update_work_item!(second,
      state: "blocked",
      blocked_reason: %{"code" => "second"},
      updated_at: DateTime.add(@now, -120, :second)
    )

    update_work_item!(other,
      state: "blocked",
      blocked_reason: %{"code" => "third"},
      updated_at: DateTime.add(@now, -60, :second)
    )

    assert {:ok, first_page} =
             Attention.list(limit: 2, include_legacy: false, now: @now)

    assert Enum.map(first_page.items, & &1.work_item_id) ==
             [work_item.work_item_id, second.work_item_id]

    assert first_page.page.has_more
    assert is_binary(first_page.page.next_cursor)

    assert {:ok, second_page} =
             Attention.list(
               limit: 2,
               after: first_page.page.next_cursor,
               include_legacy: false,
               now: @now
             )

    assert Enum.map(second_page.items, & &1.work_item_id) == [other.work_item_id]
    refute second_page.page.has_more

    assert {:ok, scoped} =
             Attention.list(
               mission_id: mission.mission_id,
               subject_kind: "work_item",
               include_legacy: false,
               now: @now
             )

    assert Enum.map(scoped.items, & &1.work_item_id) ==
             [work_item.work_item_id, second.work_item_id]

    assert {:error, {:invalid_cursor, _cursor}} =
             Attention.list(
               mission_id: mission.mission_id,
               after: first_page.page.next_cursor,
               include_legacy: false,
               now: @now
             )

    assert {:error, {:invalid_subject_kind, "agent"}} =
             Attention.list(subject_kind: "agent")

    assert {:error, {:invalid_limit, 101}} = Attention.list(limit: 101)
  end

  defp insert_mission!(mission_id) do
    %{
      mission_id: mission_id,
      key: "key:#{mission_id}",
      purpose: "Test #{mission_id}",
      lifecycle: "persistent",
      status: "active"
    }
    |> Mission.create_changeset()
    |> Repo.insert!()
  end

  defp insert_work_item!(mission, work_item_id) do
    %{
      work_item_id: work_item_id,
      mission_id: mission.id,
      kind: "test_work",
      workflow_version: 1,
      objective: "Test #{work_item_id}",
      acceptance_criteria: %{"done" => true},
      state: "ready",
      phase: "eligible",
      priority: 0,
      source: "test",
      external_key: "test:#{work_item_id}",
      version: 1
    }
    |> WorkItem.create_changeset()
    |> Repo.insert!()
  end

  defp insert_work_gate!(mission, work_item, gate_id, inserted_at) do
    %{
      gate_id: gate_id,
      mission_id: mission.id,
      work_item_id: work_item.id,
      subject_kind: "operation_call",
      operation: "github.merge_pr",
      arguments: %{"pull_request" => 406},
      preview: %{"summary" => "Approve the exact merge"},
      requester: %{"kind" => "system", "id" => "test"},
      status: "open",
      work_item_version: work_item.version,
      policy_version: "test-v1",
      grant_decision: %{"decision" => "allowed"},
      external_preconditions: %{},
      definition_fingerprint: "fingerprint:#{gate_id}",
      operation_idempotency_key: "operation:#{gate_id}"
    }
    |> WorkGate.create_changeset()
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
    |> Repo.preload([:mission, :work_item])
  end

  defp insert_call!(call_id, operation, status, inserted_at, options) do
    %{
      call_id: call_id,
      operation: operation,
      arguments: %{},
      actor: %{"kind" => "system", "id" => "test"},
      transport: "internal",
      risk: "low",
      idempotency_scope: "attention-test",
      idempotency_key: call_id,
      mission_id: options[:mission_id],
      work_item_id: options[:work_item_id],
      status: status
    }
    |> OperationCall.create_changeset()
    |> Ecto.Changeset.put_change(:error, options[:error])
    |> Ecto.Changeset.put_change(:finished_at, inserted_at)
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Ecto.Changeset.put_change(:updated_at, inserted_at)
    |> Repo.insert!()
  end

  defp insert_work_event!(mission, work_item, event_id, inserted_at) do
    %{
      event_id: event_id,
      work_item_id: work_item.id,
      mission_id: mission.id,
      kind: "work_item.transitioned",
      actor: %{"kind" => "system", "id" => "test"},
      operation: "work.transition",
      before_state: "ready",
      before_phase: work_item.phase,
      after_state: "blocked",
      after_phase: work_item.phase,
      before_version: work_item.version - 1,
      work_item_version: work_item.version,
      evidence: %{}
    }
    |> WorkEvent.create_changeset()
    |> Ecto.Changeset.put_change(:inserted_at, inserted_at)
    |> Repo.insert!()
  end

  defp update_work_item!(work_item, changes) do
    work_item
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
    |> Repo.preload(:mission, force: true)
  end

  defp put_timestamps(struct, inserted_at) do
    %{struct | inserted_at: inserted_at, updated_at: inserted_at}
  end

  defp cleanup! do
    Repo.query!("DELETE FROM workflow_node_results")
    Repo.query!("DELETE FROM workflow_runs")
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(WorkEvent)
    Repo.delete_all(WorkGate)
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(OperationCall)
    Repo.delete_all(Mission)
    Repo.delete_all(Asks.Ask)
    Repo.delete_all(Gates.Gate)
  end
end
