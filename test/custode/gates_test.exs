defmodule Custode.GatesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Gates
  alias ObanClaude.Agent

  test "gates open from transitions with their payload, and resolve on exit" do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "prune"})}
      )

    {:ok, {:awaiting_permission, %{id: action_id}}} = Agent.await(id, :awaiting_permission, 1_000)

    assert [gate] = Gates.open_gates(id)
    assert gate.kind == "approval"
    assert gate.action_id == action_id
    assert gate.detail == "prune"

    :rejected = Agent.reject_action(id, action_id, "test")
    assert Gates.open_gates(id) == []
  end

  test "question gates record the question and resolve on the answer" do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which env?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)
    assert [%{kind: "question", detail: "which env?"}] = Gates.open_gates(id)

    :processing = Agent.submit_prompt(id, "staging")
    assert Gates.open_gates(id) == []
  end

  test "reconcile! turns open routine gates into RESTART NOTICE notes, once" do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)

    gate =
      Custode.Repo.insert!(%Gates.Gate{
        agent_id: routine.id,
        kind: "approval",
        action_id: "act_1",
        detail: "delete the old logs"
      })

    orphan = Custode.Repo.insert!(%Gates.Gate{agent_id: uid("sub"), kind: "question"})

    :ok = Gates.reconcile!()

    note_path = Path.join([workspace, "inbox", "restart-gate-#{gate.id}.md"])
    content = File.read!(note_path)
    assert content =~ "RESTART NOTICE"
    assert content =~ "delete the old logs"

    assert Custode.Repo.get!(Gates.Gate, gate.id).status == "requeued"
    assert Custode.Repo.get!(Gates.Gate, orphan.id).status == "orphaned"

    # idempotent: nothing left open, no duplicate notes
    :ok = Gates.reconcile!()
    assert [_one] = Path.wildcard(Path.join([workspace, "inbox", "restart-gate-*.md"]))
  end
end
