defmodule Custode.WorkGatesTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Feed,
    Mission,
    OperationCall,
    OperationDefinition,
    OperationRegistry,
    Repo,
    WorkEvent,
    WorkGate,
    WorkGates,
    WorkItem,
    WorkItems
  }

  alias Custode.Operations.Authorization

  setup do
    cleanup!()
    on_exit(&cleanup!/0)
    :ok
  end

  test "proposal pins an exact authorized operation, preview, and preconditions durably" do
    {_mission, work_item} = insert_waiting_work!("durable", "gate-durable")
    jobs_before = Repo.aggregate(Oban.Job, :count)

    assert {:ok, gate} = propose(work_item, "gate-durable")
    assert gate.status == "open"
    assert gate.subject_kind == "transition"
    assert gate.operation == "work.transition"
    assert gate.arguments["work_item_id"] == work_item.work_item_id
    assert gate.arguments["expected_version"] == work_item.version
    assert gate.preview["effect"] == "transition_work_item"
    assert gate.work_item_version == work_item.version
    assert gate.policy_version == "policy-v1"
    assert gate.external_preconditions == %{"github_issue_revision" => "rev-1"}
    assert gate.grant_decision["decision"] == "allowed"

    assert gate.requester == %{
             "actor" => %{"id" => "requester", "kind" => "operator"},
             "transport" => "worker"
           }

    assert WorkGates.get("gate-durable") |> WorkGates.render() ==
             gate |> WorkGates.render()

    assert [persisted] = WorkGates.list_open()
    assert persisted.gate_id == "gate-durable"
    assert [persisted] = WorkGates.list_for_work_item(work_item.work_item_id)
    assert persisted.gate_id == "gate-durable"
    assert operation_call_count(work_item) == 0
    assert Repo.aggregate(Oban.Job, :count) == jobs_before

    assert {:ok, same_gate} = propose(work_item, "gate-durable")
    assert same_gate.id == gate.id
    assert Repo.aggregate(WorkGate, :count) == 1
  end

  test "proposal validates waiting scope, operation input, and requester authorization" do
    {_mission, wrong_wait} = insert_waiting_work!("wrong-wait", "another-gate")

    assert {:error, {:work_item_not_waiting_for_gate, "gate-wrong"}} =
             propose(wrong_wait, "gate-wrong")

    {_mission, work_item} = insert_waiting_work!("validation", "gate-validation")

    assert {:error, {:validation_failed, [state: :required]}} =
             propose(work_item, "gate-validation",
               arguments: %{
                 work_item_id: work_item.work_item_id,
                 expected_version: work_item.version,
                 phase: "eligible"
               }
             )

    assert {:error, {:denied, :operator_required}} =
             propose(work_item, "gate-validation", actor: %{kind: :sub_agent, id: "worker"})

    assert {:error,
            {:operation_scope_mismatch,
             %{field: :work_item_id, expected: expected, observed: "different-work"}}} =
             propose(work_item, "gate-validation",
               arguments: %{
                 work_item_id: "different-work",
                 expected_version: work_item.version,
                 state: "ready",
                 phase: "eligible",
                 evidence: %{eligibility: %{decision: "eligible"}}
               }
             )

    assert expected == work_item.work_item_id
    assert Repo.aggregate(WorkGate, :count) == 0
    assert operation_call_count(work_item) == 0
  end

  test "approval dispatches only the stored operation and preserves context" do
    {_mission, work_item} = insert_waiting_work!("approve", "gate-approve")
    assert {:ok, proposed} = propose(work_item, "gate-approve")

    assert {:ok, approved, response} =
             WorkGates.approve(
               proposed.gate_id,
               current_preconditions(),
               resolver()
             )

    assert approved.status == "approved"

    assert approved.resolver == %{
             "actor" => %{"id" => "approver", "kind" => "operator"},
             "transport" => "cli"
           }

    assert approved.operation_call_id == response.call_id
    assert response.status == :succeeded
    assert response.actor == %{kind: :operator, id: "approver"}
    assert response.transport == :cli
    assert response.correlation_id == "corr-gate-approve"
    assert response.causation_id == "cause-gate-approve"

    updated = WorkItems.get(work_item.work_item_id)
    assert updated.state == "ready"
    assert updated.phase == "eligible"
    assert updated.version == work_item.version + 1

    call = Repo.get_by!(OperationCall, call_id: approved.operation_call_id)
    assert call.arguments == proposed.arguments
    assert call.correlation_id == proposed.correlation_id
    assert call.causation_id == proposed.causation_id

    transition_event =
      WorkEvent
      |> Repo.get_by!(operation_call_id: approved.operation_call_id)

    assert transition_event.correlation_id == proposed.correlation_id
    assert transition_event.causation_id == proposed.causation_id

    assert {:error, {:gate_already_resolved, "approved"}} =
             WorkGates.approve(
               proposed.gate_id,
               current_preconditions(),
               resolver()
             )
  end

  test "changed work, policy, external revision, definition, and grant decision go stale" do
    cases = [
      {"work_item_version",
       fn work_item, registry ->
         Repo.update_all(
           from(item in WorkItem, where: item.id == ^work_item.id),
           inc: [version: 1]
         )

         {current_preconditions(), resolver(registry: registry)}
       end},
      {"policy_version",
       fn _work_item, registry ->
         {%{current_preconditions() | policy_version: "policy-v2"}, resolver(registry: registry)}
       end},
      {"external_preconditions",
       fn _work_item, registry ->
         {%{
            current_preconditions()
            | external_preconditions: %{github_issue_revision: "rev-2"}
          }, resolver(registry: registry)}
       end},
      {"definition_fingerprint",
       fn _work_item, _registry ->
         changed = definition(projection: %{title: "Changed contract"})
         {:ok, registry} = OperationRegistry.new([changed])
         {current_preconditions(), resolver(registry: registry)}
       end},
      {"grant_decision",
       fn _work_item, registry ->
         {current_preconditions(),
          resolver(actor: %{kind: :sub_agent, id: "unauthorized"}, registry: registry)}
       end}
    ]

    Enum.each(cases, fn {changed_name, mutate} ->
      suffix = "#{changed_name}-#{System.unique_integer([:positive])}"
      gate_id = "gate-#{suffix}"
      {_mission, work_item} = insert_waiting_work!(suffix, gate_id)
      registry = registry()

      assert {:ok, gate} =
               propose(work_item, gate_id,
                 registry: registry,
                 operation: "test.gated_command",
                 subject_kind: "operation_call",
                 arguments: command_arguments(work_item)
               )

      {current, resolve_options} = mutate.(work_item, registry)

      assert {:error, {:stale, changes, stale_gate}} =
               WorkGates.approve(gate.gate_id, current, resolve_options)

      assert Map.has_key?(changes, changed_name)
      assert stale_gate.status == "stale"
      assert stale_gate.resolution["changed_preconditions"] == Enum.sort(Map.keys(changes))
      assert WorkItems.get(work_item.work_item_id).state == "waiting"
      assert operation_call_count(work_item) == 0

      assert %WorkEvent{kind: "gate.stale", gate_id: ^gate_id} =
               Repo.get_by!(WorkEvent, gate_id: gate_id)

      assert [feed] = Feed.recent_by_event("work_gate_stale", limit: 1)
      assert feed["gate_id"] == gate_id

      assert {:error, {:gate_already_resolved, "stale"}} =
               WorkGates.approve(gate.gate_id, current, resolve_options)

      cleanup!()
    end)
  end

  test "rejection is typed, feed-compatible, durable, and cannot be answered twice" do
    {_mission, work_item} = insert_waiting_work!("reject", "gate-reject")
    assert {:ok, gate} = propose(work_item, "gate-reject")
    reason = %{code: "operator_refused", detail: "unsafe at this revision"}

    assert {:error, {:denied, :operator_required}} =
             WorkGates.reject(
               gate.gate_id,
               reason,
               resolver(actor: %{kind: :sub_agent, id: "unauthorized"})
             )

    assert WorkGates.get(gate.gate_id).status == "open"

    assert {:ok, rejected} = WorkGates.reject(gate.gate_id, reason, resolver())
    assert rejected.status == "rejected"

    assert rejected.reason == %{
             "code" => "operator_refused",
             "detail" => "unsafe at this revision"
           }

    assert %WorkEvent{
             kind: "gate.rejected",
             gate_id: "gate-reject",
             correlation_id: "corr-gate-reject",
             causation_id: "cause-gate-reject"
           } = Repo.get_by!(WorkEvent, gate_id: "gate-reject")

    assert [feed] = Feed.recent_by_event("work_gate_rejected", limit: 1)
    assert feed["gate_id"] == "gate-reject"
    assert feed["work_item_id"] == work_item.work_item_id

    assert {:error, {:gate_already_resolved, "rejected"}} =
             WorkGates.reject(gate.gate_id, reason, resolver())
  end

  test "an approved gate records a failed handler without hiding the decision or call" do
    {_mission, work_item} = insert_waiting_work!("failure", "gate-failure")
    failing = definition(handler: fn _arguments, _envelope -> {:error, :offline} end)
    {:ok, registry} = OperationRegistry.new([failing])

    assert {:ok, gate} =
             propose(work_item, "gate-failure",
               registry: registry,
               operation: "test.gated_command",
               subject_kind: "operation_call",
               arguments: command_arguments(work_item)
             )

    assert {:error, {:operation_failed, {:handler_failed, :offline}, approved}} =
             WorkGates.approve(
               gate.gate_id,
               current_preconditions(),
               resolver(registry: registry)
             )

    assert approved.status == "approved"
    assert approved.resolution["operation_status"] == "failed"
    assert is_binary(approved.operation_call_id)
    assert Repo.get_by!(OperationCall, call_id: approved.operation_call_id).status == "failed"
    assert WorkItems.get(work_item.work_item_id).state == "waiting"
  end

  test "an uncertain external outcome keeps the gate and operation recoverable" do
    {_mission, work_item} = insert_waiting_work!("waiting", "gate-waiting")
    waiting = definition(handler: fn _arguments, _envelope -> {:waiting, :confirming} end)
    {:ok, registry} = OperationRegistry.new([waiting])

    assert {:ok, gate} =
             propose(work_item, "gate-waiting",
               registry: registry,
               operation: "test.gated_command",
               subject_kind: "operation_call",
               arguments: command_arguments(work_item)
             )

    assert {:ok, pending, response} =
             WorkGates.approve(
               gate.gate_id,
               current_preconditions(),
               resolver(registry: registry)
             )

    assert pending.status == "open"
    assert pending.operation_call_id == response.call_id
    assert response.status == :waiting
    assert Repo.get_by!(OperationCall, call_id: response.call_id).status == "waiting"

    assert {:ok, still_pending, replay} =
             WorkGates.approve(
               gate.gate_id,
               current_preconditions(),
               resolver(registry: registry)
             )

    assert still_pending.status == "open"
    assert replay.call_id == response.call_id
    assert replay.status == :waiting
    assert replay.replayed
  end

  test "cancel and supersede are terminal and a replacement stays work-scoped" do
    {_mission, first_work} = insert_waiting_work!("cancel", "gate-cancel")
    assert {:ok, gate} = propose(first_work, "gate-cancel")

    assert {:ok, cancelled} =
             WorkGates.cancel(gate.gate_id, %{code: "no_longer_needed"}, resolver())

    assert cancelled.status == "cancelled"

    {_mission, work_item} = insert_waiting_work!("supersede", "gate-old")
    assert {:ok, old} = propose(work_item, "gate-old")

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^work_item.id),
      set: [waiting_condition: %{"kind" => "gate", "gate_id" => "gate-new"}]
    )

    refreshed = WorkItems.get(work_item.work_item_id)
    assert {:ok, replacement} = propose(refreshed, "gate-new")

    assert {:ok, superseded} =
             WorkGates.supersede(
               old.gate_id,
               replacement.gate_id,
               %{code: "proposal_replaced"},
               resolver()
             )

    assert superseded.status == "superseded"
    assert superseded.resolution["replacement_gate_id"] == replacement.gate_id
    assert replacement.status == "open"
  end

  test "legacy agent gates remain separate and open work gates block mission archive" do
    {mission, work_item} = insert_waiting_work!("legacy", "gate-legacy")
    assert {:ok, gate} = propose(work_item, "gate-legacy")

    assert Repo.get_by(Custode.Gates.Gate, action_id: gate.gate_id) == nil

    Repo.update_all(
      from(item in WorkItem, where: item.id == ^work_item.id),
      set: [
        state: "completed",
        phase: "landed",
        outcome: %{"kind" => "test"},
        completed_at: DateTime.utc_now()
      ]
    )

    assert {:error, {:active_obligation, %{kind: "gate", id: gate_id, status: "open"}}} =
             Custode.Missions.archive(mission.mission_id, nil)

    assert gate_id == gate.gate_id
  end

  defp propose(work_item, gate_id, options \\ []) do
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    attrs = %{
      gate_id: gate_id,
      work_item_id: work_item.work_item_id,
      subject_kind: Keyword.get(options, :subject_kind, "transition"),
      operation: Keyword.get(options, :operation, "work.transition"),
      arguments: Keyword.get(options, :arguments, transition_arguments(work_item)),
      policy_version: "policy-v1",
      external_preconditions: %{github_issue_revision: "rev-1"},
      correlation_id: "corr-#{gate_id}",
      causation_id: "cause-#{gate_id}"
    }

    WorkGates.propose(attrs,
      actor: Keyword.get(options, :actor, %{kind: :operator, id: "requester"}),
      transport: :worker,
      registry: registry
    )
  end

  defp resolver(options \\ []) do
    [
      actor: Keyword.get(options, :actor, %{kind: :operator, id: "approver"}),
      transport: :cli,
      registry: Keyword.get(options, :registry, OperationRegistry.default())
    ]
  end

  defp current_preconditions do
    %{
      policy_version: "policy-v1",
      external_preconditions: %{github_issue_revision: "rev-1"}
    }
  end

  defp transition_arguments(work_item) do
    %{
      work_item_id: work_item.work_item_id,
      expected_version: work_item.version,
      state: "ready",
      phase: "eligible",
      evidence: %{eligibility: %{decision: "eligible"}}
    }
  end

  defp command_arguments(work_item) do
    %{
      work_item_id: work_item.work_item_id,
      expected_version: work_item.version,
      value: "exact"
    }
  end

  defp registry do
    {:ok, registry} = OperationRegistry.new([definition()])
    registry
  end

  defp definition(overrides \\ []) do
    {:ok, definition} =
      OperationDefinition.new(
        name: "test.gated_command",
        input_schema: %{
          work_item_id: [type: :string, required: true],
          expected_version: [type: :integer, required: true],
          value: [type: :string, required: true]
        },
        result_schema: %{value: [type: :string, required: true]},
        classification: :command,
        risk: :internal_write,
        required_grants: [:operator, :system],
        authorization: &Authorization.operator_or_system/2,
        idempotency: %{required: true, scope: &command_scope/1},
        effect_preview: fn arguments, _envelope ->
          {:ok, %{effect: "test", value: arguments.value}}
        end,
        precondition: fn arguments, _envelope ->
          WorkItems.version_precondition(arguments.work_item_id, arguments.expected_version)
        end,
        handler: fn arguments, _envelope -> {:ok, %{value: arguments.value}} end,
        audit: fn arguments -> "test #{arguments.value}" end,
        projection: %{title: "Test gated command"}
      )

    struct!(definition, overrides)
  end

  defp command_scope(envelope), do: "work-item:#{envelope.arguments.work_item_id}"

  defp operation_call_count(work_item) do
    Repo.aggregate(
      from(call in OperationCall, where: call.work_item_id == ^work_item.work_item_id),
      :count
    )
  end

  defp insert_waiting_work!(suffix, gate_id) do
    mission =
      %{
        mission_id: "mission-#{suffix}",
        key: "test:#{suffix}",
        purpose: "Test #{suffix}",
        lifecycle: "persistent",
        status: "active",
        policy_ref: "policy-v1"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    work_item =
      %{
        work_item_id: "work-#{suffix}",
        mission_id: mission.id,
        kind: "github_issue_to_merge",
        workflow_version: 1,
        objective: "Test #{suffix}",
        acceptance_criteria: %{"checks" => ["approved"]},
        state: "waiting",
        phase: "triaging",
        priority: 1,
        policy_ref: "policy-v1",
        source: "work-gates-test",
        external_key: "issue-#{suffix}",
        version: 1,
        waiting_condition: %{"kind" => "gate", "gate_id" => gate_id}
      }
      |> WorkItem.create_changeset()
      |> Repo.insert!()
      |> Repo.preload(:mission)

    {mission, work_item}
  end

  defp cleanup! do
    work_items =
      Repo.all(
        from(item in WorkItem,
          where: item.source == "work-gates-test",
          select: %{id: item.id, work_item_id: item.work_item_id, mission_id: item.mission_id}
        )
      )

    work_item_ids = Enum.map(work_items, & &1.id)
    public_work_item_ids = Enum.map(work_items, & &1.work_item_id)
    mission_ids = work_items |> Enum.map(& &1.mission_id) |> Enum.uniq()

    Repo.delete_all(from(event in WorkEvent, where: event.work_item_id in ^work_item_ids))
    Repo.delete_all(from(gate in WorkGate, where: gate.work_item_id in ^work_item_ids))
    Repo.delete_all(from(item in WorkItem, where: item.id in ^work_item_ids))

    Repo.delete_all(
      from(call in OperationCall, where: call.work_item_id in ^public_work_item_ids)
    )

    Repo.delete_all(from(mission in Mission, where: mission.id in ^mission_ids))

    Repo.delete_all(
      from(entry in Feed.Entry,
        where: entry.event in ["work_gate_rejected", "work_gate_stale"]
      )
    )
  end
end
