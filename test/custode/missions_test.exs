defmodule Custode.MissionsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{
    LegacyRoutineMissionMapping,
    Mission,
    Missions,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding
  }

  alias Custode.Operations.Missions, as: MissionOperations

  setup do
    Repo.delete_all(Custode.WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(Custode.WorkItem, set: [parent_id: nil])
    Repo.delete_all(Custode.WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Mission)
    Repo.delete_all(OperationCall)
    :ok
  end

  test "persistent repository and ephemeral non-repository Missions create idempotently" do
    repo_attrs = %{
      key: "github:repository:123",
      purpose: "Operate genagent/custode",
      lifecycle: "persistent",
      policy_ref: "policy:repo:v1",
      budget_ref: "budget:repo:v1",
      context_ref: "context:repo:v1",
      targets: [
        %{
          kind: "github_repository",
          external_id: "123",
          display_name: "genagent/custode"
        }
      ]
    }

    assert {:ok, first} = create(repo_attrs, "repo-create")
    assert {:ok, replay} = create(repo_attrs, "repo-create")
    assert first.call_id == replay.call_id
    assert first.result.mission.mission_id == replay.result.mission.mission_id

    assert {:ok, same_domain_mission} = create(repo_attrs, "repo-create-again")
    assert same_domain_mission.result.mission.mission_id == first.result.mission.mission_id

    ephemeral_attrs = %{
      key: "investigation:latency",
      purpose: "Investigate cross-system latency",
      lifecycle: "ephemeral",
      retention_seconds: 0,
      targets: [
        %{kind: "topic", external_id: "latency", display_name: "Latency investigation"}
      ]
    }

    assert {:ok, ephemeral} = create(ephemeral_attrs, "ephemeral-create")
    assert ephemeral.result.mission.lifecycle == "ephemeral"
    assert length(Missions.list()) == 2
    assert Repo.aggregate(OperationCall, :count) == 3
  end

  test "repository rename updates the projection without changing stable identities" do
    mission = create_repo!("rename-create")
    [target] = mission.targets

    assert {:ok, response} =
             MissionOperations.Update.dispatch(
               mission.mission_id,
               %{
                 target: %{
                   kind: "github_repository",
                   external_id: target.external_id,
                   display_name: "genagent/custode-renamed"
                 }
               },
               invocation("rename-update")
             )

    updated = Missions.get(mission.mission_id)
    assert updated.mission_id == mission.mission_id
    assert [%{id: target_id, display_name: "genagent/custode-renamed"}] = updated.targets
    assert target_id == target.id
    assert response.result.mission.targets |> hd() |> Map.fetch!(:external_id) == "123"

    assert %OperationCall{
             operation: "mission.update",
             mission_id: mission_id,
             status: "succeeded"
           } = Repo.get_by!(OperationCall, idempotency_key: "rename-update")

    assert mission_id == mission.mission_id
  end

  test "archive names an active OperationCall and performs no state change" do
    mission = create_repo!("blocked-create")
    blocker = insert_waiting_call!(mission.mission_id)

    assert {:error,
            {:handler_failed,
             {:active_obligation, %{kind: "operation_call", id: blocker_id, status: "waiting"}}}} =
             MissionOperations.Archive.dispatch(
               mission.mission_id,
               invocation("blocked-archive")
             )

    assert blocker_id == blocker.call_id
    assert Missions.get(mission.mission_id).status == "active"

    assert %OperationCall{status: "failed", mission_id: mission_id} =
             Repo.get_by!(OperationCall, idempotency_key: "blocked-archive")

    assert mission_id == mission.mission_id
  end

  test "ephemeral retention is a named obligation; eligible Missions archive and stay queryable" do
    attrs = %{
      key: "ephemeral:retained",
      purpose: "Retain this investigation",
      lifecycle: "ephemeral",
      retention_seconds: 3_600,
      targets: [%{kind: "topic", external_id: "retained", display_name: "Retained"}]
    }

    assert {:ok, response} = create(attrs, "retained-create")
    mission_id = response.result.mission.mission_id

    assert {:error,
            {:handler_failed, {:active_obligation, %{kind: "retention", id: ^mission_id}}}} =
             MissionOperations.Archive.dispatch(mission_id, invocation("retained-archive"))

    mission = create_repo!("archive-create")

    assert {:ok, archived} =
             MissionOperations.Archive.dispatch(
               mission.mission_id,
               invocation("archive-success")
             )

    assert archived.result.mission.status == "archived"

    assert %Mission{status: "archived", archived_at: %DateTime{}} =
             Missions.get(mission.mission_id)

    assert {:error, {:handler_failed, :mission_archived}} =
             MissionOperations.Update.dispatch(
               mission.mission_id,
               %{purpose: "must not change"},
               invocation("archived-update")
             )
  end

  test "bootstrap declarations create-or-find without syncing database changes back to config" do
    declaration = %{
      key: "bootstrap:system",
      purpose: "Operate Custode",
      lifecycle: "persistent",
      targets: [%{kind: "system", external_id: "custode", display_name: "Custode"}]
    }

    put_env!(:missions, [declaration])
    assert :ok = Missions.bootstrap!()

    mission = Missions.get_by_key("bootstrap:system")
    assert mission.purpose == "Operate Custode"

    mission
    |> Mission.update_changeset(%{purpose: "Operator-owned purpose"})
    |> Repo.update!()

    assert :ok = Missions.bootstrap!()
    assert Missions.get_by_key("bootstrap:system").purpose == "Operator-owned purpose"

    assert %OperationCall{
             actor: %{"kind" => "system", "id" => "bootstrap"},
             transport: "system",
             grant: "system",
             status: "succeeded"
           } =
             Repo.get_by!(OperationCall, idempotency_key: "bootstrap:mission:bootstrap:system:v1")
  end

  defp create_repo!(key) do
    attrs = %{
      key: "github:repository:123",
      purpose: "Operate genagent/custode",
      lifecycle: "persistent",
      targets: [
        %{
          kind: "github_repository",
          external_id: "123",
          display_name: "genagent/custode"
        }
      ]
    }

    {:ok, response} = create(attrs, key)
    Missions.get(response.result.mission.mission_id)
  end

  defp create(attrs, key), do: MissionOperations.Create.dispatch(attrs, invocation(key))

  defp invocation(key) do
    [
      actor: %{kind: :operator, id: "human"},
      transport: :worker,
      idempotency_key: key
    ]
  end

  defp insert_waiting_call!(mission_id) do
    attrs = %{
      call_id: Ecto.UUID.generate(),
      operation: "test.waiting",
      arguments: %{},
      actor: %{kind: "operator", id: "human"},
      transport: "worker",
      risk: "internal_write",
      idempotency_scope: mission_id,
      idempotency_key: "blocker-#{System.unique_integer([:positive])}",
      mission_id: mission_id,
      status: "waiting"
    }

    attrs |> OperationCall.create_changeset() |> Repo.insert!()
  end
end
