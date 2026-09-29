defmodule Custode.AgentAuthorizationSnapshotTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, Repo}

  setup do
    id = uid("authorization-snapshot")

    on_exit(fn ->
      Repo.delete_all(
        from(snapshot in AgentAuthorizationSnapshot, where: snapshot.routine_id == ^id)
      )
    end)

    %{id: id}
  end

  test "an execution revision keeps its first exact authority projection", %{id: id} do
    revision = String.duplicate("a", 64)

    routine = %{
      id: id,
      role: :backlog_worker,
      repo: "acme/original",
      workspace: "/tmp/#{id}/notebook",
      working_dir: "/tmp/#{id}/repo"
    }

    assert :ok = AgentAuthorizationSnapshot.put(routine, revision)
    assert :ok = AgentAuthorizationSnapshot.put(routine, revision)

    assert {:error, :snapshot_conflict} =
             AgentAuthorizationSnapshot.put(%{routine | role: :caretaker}, revision)

    assert %{
             id: ^id,
             execution_revision: ^revision,
             role: :backlog_worker,
             repo: "acme/original"
           } = AgentAuthorizationSnapshot.get(id, revision)
  end

  test "an unknown persisted role fails closed", %{id: id} do
    revision = String.duplicate("b", 64)

    Repo.insert!(%AgentAuthorizationSnapshot{
      routine_id: id,
      execution_revision: revision,
      role: "future_operator",
      workspace: "/tmp/#{id}/notebook",
      working_dir: "/tmp/#{id}/repo"
    })

    assert {:error, {:unknown_role, "future_operator"}} =
             AgentAuthorizationSnapshot.get(id, revision)
  end
end
