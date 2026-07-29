defmodule Custode.WorkItemsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    LegacyRoutineMissionMapping,
    Mission,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding,
    WorkEvent,
    WorkItem,
    WorkItems
  }

  alias Custode.Operations.Missions, as: MissionOperations
  alias Custode.Operations.WorkItems, as: WorkOperations

  setup do
    Repo.delete_all(WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Mission)
    Repo.delete_all(OperationCall)
    :ok
  end

  test "work identity is Mission-scoped, source-stable, and append-only from creation" do
    mission = create_mission!("mission-create")
    attrs = work_attrs(mission)

    assert {:ok, first} = create_work(attrs, "work-create")
    assert {:ok, same_domain_record} = create_work(attrs, "work-create-again")

    work_item = first.result.work_item
    assert work_item.work_item_id == same_domain_record.result.work_item.work_item_id
    assert work_item.mission_id == mission.mission_id
    assert work_item.state == "proposed"
    assert work_item.phase == "discovered"
    assert work_item.version == 1
    assert Repo.aggregate(WorkItem, :count) == 1
    assert Repo.aggregate(WorkEvent, :count) == 1

    assert [%WorkEvent{} = event] = WorkItems.list_events(work_item.work_item_id)
    assert event.kind == "work_item.created"
    assert event.operation == "work.create"
    assert event.work_item_version == 1
    assert event.actor == %{"kind" => "operator", "id" => "human"}

    assert {:ok, other_source} =
             attrs
             |> Map.merge(%{source: "operator", external_key: attrs.external_key})
             |> create_work("other-source")

    refute other_source.result.work_item.work_item_id == work_item.work_item_id
    assert Repo.aggregate(WorkItem, :count) == 2
  end

  test "create requires an active Mission and parent work stays in that Mission" do
    mission = create_mission!("parent-mission")
    parent = create_work!(work_attrs(mission), "parent")

    child_attrs =
      mission
      |> work_attrs("github:123:issue:2")
      |> Map.put(:parent_work_item_id, parent.work_item_id)

    assert {:ok, child} = create_work(child_attrs, "child")
    assert child.result.work_item.parent_work_item_id == parent.work_item_id

    other_mission = create_mission!("other-mission", "github:repository:456")

    assert {:error, {:handler_failed, :parent_mission_mismatch}} =
             other_mission
             |> work_attrs("github:456:issue:2")
             |> Map.put(:parent_work_item_id, parent.work_item_id)
             |> create_work("cross-mission-child")

    assert {:error, {:handler_failed, {:unknown_mission, "missing"}}} =
             %{work_attrs(mission) | mission_id: "missing", external_key: "missing:issue:1"}
             |> create_work("missing-mission")

    assert {:ok, _archived} =
             MissionOperations.Archive.dispatch(
               other_mission.mission_id,
               invocation("archive-other")
             )

    assert {:error, {:handler_failed, :mission_archived}} =
             other_mission
             |> work_attrs("github:456:issue:3")
             |> create_work("archived-mission-work")
  end

  test "canonical states, phase pairs, phase edges, and evidence are validated" do
    mission = create_mission!("validation-mission")

    assert {:error, {:handler_failed, {:unknown_phase, "invented"}}} =
             mission
             |> work_attrs()
             |> Map.put(:phase, "invented")
             |> create_work("unknown-phase")

    work_item = create_work!(work_attrs(mission), "validation-work")

    for invalid_state <- ["failed", "merge_ready"] do
      assert {:error, {:handler_failed, {:invalid_state, ^invalid_state}}} =
               transition(
                 work_item.work_item_id,
                 %{expected_version: 1, state: invalid_state, phase: "discovered"},
                 "invalid-state-#{invalid_state}"
               )
    end

    assert {:error,
            {:handler_failed, {:illegal_state_phase, %{state: "ready", phase: "discovered"}}}} =
             transition(
               work_item.work_item_id,
               %{expected_version: 1, state: "ready", phase: "discovered"},
               "illegal-pair"
             )

    assert {:error, {:handler_failed, {:missing_evidence, ["source_snapshot"]}}} =
             transition(
               work_item.work_item_id,
               %{expected_version: 1, state: "proposed", phase: "triaging"},
               "missing-evidence"
             )

    assert {:ok, triaging} =
             transition(
               work_item.work_item_id,
               %{
                 expected_version: 1,
                 state: "proposed",
                 phase: "triaging",
                 evidence: %{source_snapshot: %{revision: "r1"}}
               },
               "triaging"
             )

    assert triaging.result.work_item.version == 2

    assert {:error,
            {:handler_failed,
             {:illegal_phase_transition, %{from: "triaging", to: "implementation_ready"}}}} =
             transition(
               work_item.work_item_id,
               %{
                 expected_version: 2,
                 state: "ready",
                 phase: "implementation_ready",
                 evidence: %{context_bundle_digest: "digest"}
               },
               "skip-phase"
             )
  end

  test "active, waiting, blocked, and terminal states require their structured context" do
    mission = create_mission!("state-context-mission")
    work_item = create_work!(work_attrs(mission), "state-context-work")
    ready = advance_to_ready!(work_item)

    assert {:error, {:handler_failed, :active_reference_required}} =
             transition(
               ready.work_item_id,
               %{expected_version: ready.version, state: "active", phase: "preparing_workspace"},
               "active-without-reference"
             )

    assert {:ok, active} =
             transition(
               ready.work_item_id,
               %{
                 expected_version: ready.version,
                 state: "active",
                 phase: "preparing_workspace",
                 active_attempt_id: "attempt-future"
               },
               "active-with-attempt"
             )

    assert active.result.work_item.active_attempt_id == "attempt-future"

    assert {:error, {:handler_failed, :waiting_condition_required}} =
             transition(
               ready.work_item_id,
               %{
                 expected_version: active.result.work_item.version,
                 state: "waiting",
                 phase: "preparing_workspace"
               },
               "waiting-without-condition"
             )

    assert {:ok, waiting} =
             transition(
               ready.work_item_id,
               %{
                 expected_version: active.result.work_item.version,
                 state: "waiting",
                 phase: "preparing_workspace",
                 waiting_condition: %{kind: "timer", wake_at: "tomorrow"}
               },
               "waiting"
             )

    assert waiting.result.work_item.active_attempt_id == nil

    assert {:error, {:handler_failed, :blocked_reason_required}} =
             transition(
               ready.work_item_id,
               %{
                 expected_version: waiting.result.work_item.version,
                 state: "blocked",
                 phase: "preparing_workspace"
               },
               "blocked-without-reason"
             )

    assert {:error, {:handler_failed, :terminal_outcome_required}} =
             transition(
               ready.work_item_id,
               %{
                 expected_version: waiting.result.work_item.version,
                 state: "cancelled",
                 phase: "preparing_workspace"
               },
               "cancelled-without-outcome"
             )
  end

  test "one concurrent transition wins and the stale call records expected and observed versions" do
    mission = create_mission!("concurrency-mission")
    work_item = create_work!(work_attrs(mission), "concurrency-work")

    calls =
      for suffix <- ["one", "two"] do
        Task.async(fn ->
          transition(
            work_item.work_item_id,
            %{
              expected_version: 1,
              state: "waiting",
              phase: "discovered",
              waiting_condition: %{kind: "callback", key: suffix}
            },
            "race-#{suffix}",
            correlation_id: "corr-race",
            causation_id: "cause-race"
          )
        end)
      end

    results = Enum.map(calls, &Task.await(&1, 5_000))

    assert Enum.count(results, &match?({:ok, _response}, &1)) == 1

    assert Enum.count(
             results,
             &match?({:error, {:stale, :work_item_version_changed}}, &1)
           ) == 1

    updated = WorkItems.get(work_item.work_item_id)
    assert updated.version == 2
    assert updated.state == "waiting"
    assert length(WorkItems.list_events(work_item.work_item_id)) == 2

    stale_call =
      Repo.one!(
        from(call in OperationCall,
          where: call.idempotency_key in ["race-one", "race-two"] and call.status == "stale"
        )
      )

    assert stale_call.preconditions == %{
             "work_item" => %{"expected" => 1, "observed" => 2}
           }

    transition_event = List.last(WorkItems.list_events(work_item.work_item_id))
    assert transition_event.operation == "work.transition"
    assert transition_event.before_state == "proposed"
    assert transition_event.after_state == "waiting"
    assert transition_event.before_version == 1
    assert transition_event.work_item_version == 2
    assert transition_event.correlation_id == "corr-race"
    assert transition_event.causation_id == "cause-race"
  end

  test "dry runs preview without changing work or appending an event" do
    mission = create_mission!("dry-run-mission")
    work_item = create_work!(work_attrs(mission), "dry-run-work")

    assert {:ok, preview} =
             transition(
               work_item.work_item_id,
               %{
                 expected_version: 1,
                 state: "waiting",
                 phase: "discovered",
                 waiting_condition: %{kind: "timer"}
               },
               "dry-run-transition",
               dry_run: true
             )

    assert preview.status == :dry_run
    assert preview.effect_preview.effect == "transition_work_item"
    assert WorkItems.get(work_item.work_item_id).version == 1
    assert length(WorkItems.list_events(work_item.work_item_id)) == 1
  end

  test "a Mission cannot archive while it owns nonterminal work" do
    mission = create_mission!("archive-obligation-mission")
    work_item = create_work!(work_attrs(mission), "archive-obligation-work")

    assert {:error,
            {:handler_failed,
             {:active_obligation, %{kind: "work_item", id: work_item_id, status: "proposed"}}}} =
             MissionOperations.Archive.dispatch(
               mission.mission_id,
               invocation("archive-with-work")
             )

    assert work_item_id == work_item.work_item_id
    assert Custode.Missions.get(mission.mission_id).status == "active"
  end

  test "terminal work can leave terminal state only through work.reopen" do
    mission = create_mission!("reopen-mission")
    work_item = create_work!(work_attrs(mission), "reopen-work")
    force_completed!(work_item)

    assert {:error, {:handler_failed, :terminal_work_requires_reopen}} =
             transition(
               work_item.work_item_id,
               %{
                 expected_version: 2,
                 state: "ready",
                 phase: "eligible",
                 evidence: %{eligibility: %{decision: "eligible"}}
               },
               "ordinary-terminal-transition"
             )

    assert {:error, {:validation_failed, [acceptance_review: :required]}} =
             WorkOperations.Reopen.dispatch(
               work_item.work_item_id,
               %{
                 expected_version: 2,
                 state: "ready",
                 phase: "eligible",
                 reason: %{kind: "new_evidence"}
               },
               invocation("reopen-without-review")
             )

    assert {:ok, reopened} =
             WorkOperations.Reopen.dispatch(
               work_item.work_item_id,
               %{
                 expected_version: 2,
                 state: "ready",
                 phase: "eligible",
                 reason: %{kind: "new_evidence", detail: "requirements changed"},
                 acceptance_review: %{reviewed_by: "human", decision: "reopen"},
                 acceptance_criteria: %{checks: ["new acceptance"]}
               },
               invocation("reopen")
             )

    assert reopened.result.work_item.state == "ready"
    assert reopened.result.work_item.version == 3
    assert reopened.result.work_item.outcome == nil
    assert reopened.result.work_item.completed_at == nil
    assert reopened.result.work_item.acceptance_criteria == %{checks: ["new acceptance"]}

    event = List.last(WorkItems.list_events(work_item.work_item_id))
    assert event.kind == "work_item.reopened"
    assert event.before_state == "completed"
    assert event.after_state == "ready"
    assert event.evidence["reason"]["kind"] == "new_evidence"
    assert event.evidence["acceptance_review"]["decision"] == "reopen"
  end

  test "new work operations are operator-or-system only and ready work has a deterministic next command" do
    mission = create_mission!("authorization-mission")

    assert {:error, {:denied, :operator_required}} =
             WorkOperations.Create.dispatch(
               work_attrs(mission),
               actor: %{kind: :sub_agent, id: "worker"},
               transport: :worker,
               idempotency_key: "denied-work-create"
             )

    assert Repo.aggregate(WorkItem, :count) == 0

    work_item = create_work!(work_attrs(mission), "next-command-work")
    ready = advance_to_ready!(work_item)

    assert {:ok, %{action: :dispatch_attempt, kind: "prepare_workspace"}} =
             WorkItems.next_command(ready.work_item_id)
  end

  defp create_mission!(key, mission_key \\ "github:repository:123") do
    external_id = mission_key |> String.split(":") |> List.last()

    attrs = %{
      key: mission_key,
      purpose: "Operate repository #{external_id}",
      lifecycle: "persistent",
      targets: [
        %{
          kind: "github_repository",
          external_id: external_id,
          display_name: "genagent/repository-#{external_id}"
        }
      ]
    }

    {:ok, response} = MissionOperations.Create.dispatch(attrs, invocation(key))
    Custode.Missions.get(response.result.mission.mission_id)
  end

  defp work_attrs(mission, external_key \\ "github:123:issue:1") do
    %{
      mission_id: mission.mission_id,
      kind: "github_issue_to_merge",
      workflow_version: 1,
      objective: "Land issue safely",
      acceptance_criteria: %{checks: ["tests pass", "review complete"]},
      phase: "discovered",
      priority: 10,
      source: "github",
      external_key: external_key,
      evidence: %{source_snapshot: %{revision: "r1"}}
    }
  end

  defp create_work!(attrs, key) do
    {:ok, response} = create_work(attrs, key)
    WorkItems.get(response.result.work_item.work_item_id)
  end

  defp create_work(attrs, key),
    do: WorkOperations.Create.dispatch(attrs, invocation(key))

  defp transition(work_item_id, attrs, key, options \\ []) do
    invocation =
      key
      |> invocation()
      |> Keyword.merge(options)

    WorkOperations.Transition.dispatch(work_item_id, attrs, invocation)
  end

  defp advance_to_ready!(work_item) do
    {:ok, triaging} =
      transition(
        work_item.work_item_id,
        %{
          expected_version: work_item.version,
          state: "proposed",
          phase: "triaging",
          evidence: %{source_snapshot: %{revision: "r1"}}
        },
        "advance-triaging-#{work_item.work_item_id}"
      )

    {:ok, ready} =
      transition(
        work_item.work_item_id,
        %{
          expected_version: triaging.result.work_item.version,
          state: "ready",
          phase: "eligible",
          evidence: %{eligibility: %{decision: "eligible"}}
        },
        "advance-eligible-#{work_item.work_item_id}"
      )

    WorkItems.get(ready.result.work_item.work_item_id)
  end

  defp force_completed!(work_item) do
    now = DateTime.utc_now()

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^work_item.id),
      set: [
        state: "completed",
        phase: "landed",
        version: 2,
        outcome: %{"kind" => "merged"},
        completed_at: now,
        updated_at: now
      ]
    )
  end

  defp invocation(key) do
    [
      actor: %{kind: :operator, id: "human"},
      transport: :worker,
      idempotency_key: key,
      correlation_id: "corr-#{key}",
      causation_id: "cause-#{key}"
    ]
  end
end
