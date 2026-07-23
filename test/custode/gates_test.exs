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

    # the transition came from a cast, so the row the handler writes may not
    # exist at the instant `await` returns -- see `eventually/2`'s docs (#257)
    gate =
      eventually(fn ->
        assert [gate] = Gates.open_gates(id)
        gate
      end)

    assert gate.kind == "approval"
    assert gate.action_id == action_id
    assert gate.detail == "prune"

    # reject_action/3 is a call and replies after sync_transition: the resolve
    # is already written here, so this read needs no retry
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

    eventually(fn ->
      assert [%{kind: "question", detail: "which env?"}] = Gates.open_gates(id)
    end)

    # submit_prompt/3 is a call: the answer's transition is written by the
    # time it replies
    :processing = Agent.submit_prompt(id, "staging")
    assert Gates.open_gates(id) == []
  end

  # The flake in #257, made permanent rather than accidental. Detaching
  # `custode-gates` and re-attaching it behind a sleeping handler puts its
  # insert at the back of the transition's handler chain, so the window
  # between "the registry says awaiting_permission" and "the gate row
  # exists" is always wide instead of usually zero. Nothing here is
  # artificial: it is the ordering CI hits under load.
  test "the gate row lands after await/3 returns, and the assertion survives it" do
    slow = "slow-transition-#{System.unique_integer([:positive])}"

    :ok = :telemetry.detach("custode-gates")

    :ok =
      :telemetry.attach(
        slow,
        [:oban_claude, :agent, :transition],
        fn _event, _measurements, _meta, _config -> Process.sleep(150) end,
        nil
      )

    :ok = Custode.Gates.attach()

    on_exit(fn ->
      :telemetry.detach(slow)
      :telemetry.detach("custode-gates")
      Custode.Gates.attach()
    end)

    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "prune"})}
      )

    {:ok, {:awaiting_permission, _action}} = Agent.await(id, :awaiting_permission, 1_000)

    # the agent process is still inside the sleeping handler here
    assert Gates.open_gates(id) == []

    eventually(fn -> assert [%{detail: "prune"}] = Gates.open_gates(id) end)
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
