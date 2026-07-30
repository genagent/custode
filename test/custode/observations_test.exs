defmodule Custode.ObservationsTest do
  # Systemic-drift Observations becoming bounded control work (#246): the
  # aggregate, the versioned threshold, the posture, the Gate, and the two
  # guards against a control item raising control work about itself.
  use ExUnit.Case, async: false

  alias Custode.{Mission, MissionTarget, Observation, Observations, Repo, WorkItems}
  alias Custode.WorkKinds.SystemicDriftControl

  setup do
    cleanup!()
    previous = Application.get_env(:custode, :control_work_policy)

    on_exit(fn ->
      cleanup!()

      if previous,
        do: Application.put_env(:custode, :control_work_policy, previous),
        else: Application.delete_env(:custode, :control_work_policy)
    end)

    Application.delete_env(:custode, :control_work_policy)
    :ok
  end

  test "repeated sightings produce one stable aggregate, not a pile of rows" do
    mission!("genagent/drift")

    for _ <- 1..2, do: {:ok, _} = sight("ci:pr-42")

    assert [observation] = Repo.all(Observation)
    assert observation.occurrences == 2
    assert observation.disposition == "watching"
    assert DateTime.compare(observation.last_observed_at, observation.first_observed_at) != :lt

    # the aggregate is the same row, addressed by its deduplication key
    assert Observations.get("ci:pr-42").id == observation.id
  end

  test "crossing the threshold creates one gated control WorkItem carrying its evidence" do
    mission = mission!("genagent/drift")

    for _ <- 1..3, do: {:ok, _} = sight("ci:pr-42", evidence: %{"check" => "mix test"})

    observation = Observations.get("ci:pr-42")
    assert observation.disposition == "gated"
    assert observation.occurrences == 3

    # threshold AND policy versions are both recorded on the aggregate
    assert observation.threshold_version == "drift:v1"
    assert observation.policy_version == "control:v1"
    assert observation.control_work_item_id
    assert observation.gate_id

    work_item = WorkItems.get(observation.control_work_item_id)
    assert work_item.kind == "systemic_drift_control"
    assert work_item.state == "waiting"
    assert work_item.phase == "awaiting_decision"
    assert work_item.mission_id == mission.id

    # The triggering evidence is retained on the WorkItem's creation event,
    # which is where the kernel keeps evidence. It is durable and traversable
    # from the WorkItem rather than living only beside it on the aggregate.
    evidence = creation_evidence(work_item)

    assert get_in(evidence, ["observation", "dedup_key"]) == "ci:pr-42"
    assert get_in(evidence, ["observation", "occurrences"]) == 3
    assert get_in(evidence, ["observation", "evidence", "check"]) == "mix test"
    assert get_in(evidence, ["observation", "first_observed_at"]) =~ "T"
    assert get_in(evidence, ["threshold", "min_occurrences"]) == 3
    assert get_in(evidence, ["threshold", "version"]) == "drift:v1"
    assert get_in(evidence, ["work_policy", "posture"]) == "ask"
  end

  test "the ask posture opens a Gate against the admitting transition" do
    mission!("genagent/drift")
    for _ <- 1..3, do: {:ok, _} = sight("ci:pr-42")

    observation = Observations.get("ci:pr-42")
    gate = Repo.get_by(Custode.WorkGate, gate_id: observation.gate_id)

    assert gate.status == "open"
    assert gate.operation == "work.transition"
    assert gate.subject_kind == "transition"
    assert gate.grant_decision["work_policy"]["posture"] == "ask"
  end

  test "an auto posture admits the control WorkItem without a Gate" do
    Application.put_env(:custode, :control_work_policy, [
      %{
        name: "control.auto",
        selectors: %{target: "genagent/drift"},
        posture: :auto,
        reason: "this repository's drift is admitted without asking"
      }
    ])

    mission!("genagent/drift")
    for _ <- 1..3, do: {:ok, _} = sight("ci:pr-42")

    observation = Observations.get("ci:pr-42")
    assert observation.disposition == "proposed"
    assert observation.gate_id == nil

    work_item = WorkItems.get(observation.control_work_item_id)
    assert work_item.state == "ready"
    assert work_item.phase == "admitted"
  end

  test "an ineligible posture refuses visibly and creates no work" do
    Application.put_env(:custode, :control_work_policy, [
      %{
        name: "control.ineligible",
        selectors: %{target: "genagent/drift"},
        posture: :ineligible,
        reason: "this repository is being handled by a human"
      }
    ])

    mission!("genagent/drift")
    for _ <- 1..3, do: {:ok, _} = sight("ci:pr-42")

    observation = Observations.get("ci:pr-42")
    assert observation.disposition == "ineligible"
    assert observation.control_work_item_id == nil
    assert observation.disposition_reason["reason"] =~ "handled by a human"

    # visible and auditable, but nothing was created
    assert observation.policy_version == "control:v1"
    assert Repo.all(Custode.WorkItem) == []
  end

  test "an observation about control work is rejected and never promotes" do
    mission!("genagent/drift")

    for _ <- 1..5 do
      {:ok, _} =
        Observations.record(%{
          source: "control",
          target: "genagent/drift",
          dedup_key: "control:already-raised"
        })
    end

    observation = Observations.get("control:already-raised")
    assert observation.disposition == "rejected"
    assert observation.occurrences == 1
    assert observation.control_work_item_id == nil
    assert observation.disposition_reason["reason"] =~ "cannot raise control work"
  end

  test "an aggregate with no Mission keeps watching rather than failing" do
    # no mission targets this repository
    for _ <- 1..4, do: {:ok, _} = sight("ci:pr-7", target: "genagent/unknown")

    observation = Observations.get("ci:pr-7")
    assert observation.disposition == "watching"
    assert observation.occurrences == 4
    assert observation.control_work_item_id == nil
  end

  test "promotion is idempotent for an already dispositioned aggregate" do
    mission!("genagent/drift")
    for _ <- 1..3, do: {:ok, _} = sight("ci:pr-42")

    before = Observations.get("ci:pr-42")
    work_items = Repo.all(Custode.WorkItem) |> length()

    {:ok, _} = sight("ci:pr-42")
    {:ok, again} = Observations.promote(Observations.get("ci:pr-42"))

    assert again.control_work_item_id == before.control_work_item_id
    assert again.gate_id == before.gate_id
    assert Repo.all(Custode.WorkItem) |> length() == work_items
  end

  describe "the control work kind" do
    test "never dispatches itself, in any non-waiting state" do
      for {state, phase} <- [
            {"proposed", "observed"},
            {"ready", "admitted"},
            {"active", "admitted"},
            {"completed", "resolved"},
            {"cancelled", "declined"}
          ] do
        item = %Custode.WorkItem{state: state, phase: phase}
        assert {:ok, %{action: :none}} = SystemicDriftControl.V1.next_command(item, %{})
      end
    end

    test "waits on its gate rather than acting" do
      item = %Custode.WorkItem{
        state: "waiting",
        phase: "awaiting_decision",
        waiting_condition: %{"kind" => "gate"}
      }

      assert {:ok, %{action: :wait}} = SystemicDriftControl.V1.next_command(item, %{})
    end

    test "rejects an illegal state and phase pairing" do
      assert :ok = SystemicDriftControl.V1.validate_pair("waiting", "awaiting_decision")

      assert {:error, {:unknown_phase, "nope"}} =
               SystemicDriftControl.V1.validate_pair("ready", "nope")

      assert {:error, {:illegal_state_phase, _}} =
               SystemicDriftControl.V1.validate_pair("completed", "observed")
    end
  end

  test "recording requires the fields that make an observation evidence" do
    assert {:error, {:missing_observation_fields, missing}} =
             Observations.record(%{source: "ci", target: "genagent/drift"})

    assert missing == [:dedup_key]
  end

  defp creation_evidence(work_item) do
    Custode.WorkEvent
    |> Repo.all()
    |> Enum.filter(&(&1.work_item_id == work_item.id))
    |> Enum.map(& &1.evidence)
    |> Enum.find(%{}, &is_map(&1[<<"observation">>]))
  end

  defp sight(dedup_key, options \\ []) do
    Observations.record(%{
      source: Keyword.get(options, :source, "ci-status"),
      target: Keyword.get(options, :target, "genagent/drift"),
      dedup_key: dedup_key,
      revision: "abc123",
      evidence: Keyword.get(options, :evidence, %{})
    })
  end

  defp mission!(repository) do
    mission =
      %{
        mission_id: "mission-" <> String.replace(repository, "/", "-"),
        key: repository,
        purpose: "drift fixture",
        lifecycle: "persistent",
        status: "active",
        policy_ref: "control:v1"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    Repo.insert!(%MissionTarget{
      mission_id: mission.id,
      kind: "github_repository",
      external_id: repository,
      display_name: repository
    })

    mission
  end

  # EVERY table that references missions, child-first. Omitting any of them
  # passes when this file runs alone and fails with a foreign-key error the
  # moment another module leaves one of those rows behind -- which is exactly
  # what happened once observations_test, definitions_test and
  # availability_test all landed and changed the execution order.
  defp cleanup! do
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE work_items SET parent_id = NULL")

    for table <- ~w(
          observations
          work_events
          work_gates
          attempts
          context_bundles
          artifacts
          workspace_leases
          role_bindings
          legacy_routine_mission_mappings
          work_items
          operation_calls
          mission_targets
          missions
        ) do
      Repo.query!("DELETE FROM #{table}")
    end
  end
end
