defmodule Custode.GatesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias ObanClaude.Agent

  doctest Custode.Gates.Class

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

  # drives a stub agent to an open approval gate and returns {id, action_id}
  defp gated_agent!(action) do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => action})}
      )

    {:ok, {:awaiting_permission, %{id: action_id}}} = Agent.await(id, :awaiting_permission, 1_000)
    eventually(fn -> assert [_gate] = Gates.open_gates(id) end)
    {id, action_id}
  end

  defp gate_for(id) do
    import Ecto.Query, only: [from: 2]
    Custode.Repo.one!(from(g in Gates.Gate, where: g.agent_id == ^id))
  end

  describe "the outcome of a gate (#448)" do
    test "a rejection records that it was one, who, from where, and why" do
      {id, action_id} = gated_agent!("force-push main")

      :rejected =
        Custode.reject_with_note(id, action_id, "never force-push a default branch",
          via: :cli,
          by: "operator"
        )

      gate = gate_for(id)
      assert gate.status == "resolved"
      assert gate.outcome == "rejected"
      assert gate.reason == "never force-push a default branch"
      assert gate.decided_via == "cli"
      assert gate.decided_by == "operator"
    end

    test "an approval records that it was one, and from which surface" do
      {id, action_id} = gated_agent!("open a draft PR")

      :processing = Custode.approve_action(id, action_id, via: :liveview)

      gate = gate_for(id)
      assert gate.status == "resolved"
      assert gate.outcome == "approved"
      assert gate.decided_via == "liveview"
      assert gate.decided_by == "operator"
      assert gate.reason == nil
    end

    test "a decision that reaches the engine directly still records its outcome" do
      {id, action_id} = gated_agent!("prune")

      :rejected = Agent.reject_action(id, action_id, "test")

      gate = gate_for(id)
      assert gate.outcome == "rejected"
      assert gate.decided_via == nil
    end

    test "record_decision narrows to the action and is not an error when nothing is open" do
      {id, action_id} = gated_agent!("prune")

      assert Gates.record_decision(id, "act_someone_else", via: :mcp) == 0
      assert Gates.record_decision(id, action_id, via: :mcp, by: "custode") == 1
      assert Gates.record_decision(uid("nobody"), nil, via: :mcp) == 0

      assert gate_for(id).decided_by == "custode"
    end

    test "approval_rates counts decided approvals per agent and leaves the undecided out" do
      {approved_id, a1} = gated_agent!("one")
      :processing = Custode.approve_action(approved_id, a1, via: :cli)

      {rejected_id, a2} = gated_agent!("two")
      :rejected = Custode.reject_with_note(rejected_id, a2, "no", via: :cli)

      {open_id, _a3} = gated_agent!("three")

      rates = Map.new(Gates.approval_rates(), &{&1.agent_id, &1})

      assert %{approved: 1, rejected: 0, rate: 1.0} = rates[approved_id]
      assert %{approved: 0, rejected: 1, rate: +0.0} = rates[rejected_id]
      refute Map.has_key?(rates, open_id)
    end
  end

  describe "the class of action a gate asks for (#451)" do
    # The engine's worker emits [:oban_claude, :run, :stop] and THEN casts
    # job_finished, so the turn's feed entry exists before the gate opens.
    # These drive the two in the same order.
    defp gated_agent!(action, fields) do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      result =
        structured_result(
          Map.merge(%{"directive" => "request_permission", "action" => action}, fields)
        )

      :ok =
        Ingest.handle_event(
          [:oban_claude, :run, :stop],
          %{cost_usd: 0.0},
          %{result: result, job: %{meta: %{"agent_id" => id}}},
          nil
        )

      :ok = Agent.job_finished(id, {:ok, result})

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(id, :awaiting_permission, 1_000)

      eventually(fn -> assert [_gate] = Gates.open_gates(id) end)
      {id, action_id}
    end

    test "a gate carries the class its turn declared" do
      {id, _action_id} = gated_agent!("mark #490 ready", %{"action_class" => "ready_pr"})
      assert [%{class: "ready_pr", detail: "mark #490 ready"}] = Gates.open_gates(id)
    end

    test "a value outside the list is other, and nothing declared is nil" do
      {unknown, _a1} = gated_agent!("ship it", %{"action_class" => "deploy"})
      assert [%{class: "other"}] = Gates.open_gates(unknown)

      {silent, _a2} = gated_agent!("prune", %{})
      assert [%{class: nil}] = Gates.open_gates(silent)
    end

    test "a class is not inherited from an earlier turn" do
      {id, action_id} = gated_agent!("mark #490 ready", %{"action_class" => "ready_pr"})
      :rejected = Agent.reject_action(id, action_id, "not yet")

      # the next gate is raised by a turn that says nothing about its class
      :processing = Agent.submit_prompt(id, "y")
      silent = structured_result(%{"directive" => "request_permission", "action" => "prune"})

      :ok =
        Ingest.handle_event(
          [:oban_claude, :run, :stop],
          %{cost_usd: 0.0},
          %{result: silent, job: %{meta: %{"agent_id" => id}}},
          nil
        )

      :ok = Agent.job_finished(id, {:ok, silent})
      {:ok, _status} = Agent.await(id, :awaiting_permission, 1_000)

      assert [%{class: nil, detail: "prune"}] =
               eventually(fn ->
                 assert [%{detail: "prune"}] = gates = Gates.open_gates(id)
                 gates
               end)
    end

    test "approval_rates_by_class counts only gates that declared one, in class order" do
      Custode.Repo.query!("DELETE FROM gates")

      {a, a1} = gated_agent!("open a PR", %{"action_class" => "implement"})
      :processing = Custode.approve_action(a, a1, via: :cli)

      {b, b1} = gated_agent!("open another", %{"action_class" => "implement"})
      :rejected = Custode.reject_with_note(b, b1, "no", via: :cli)

      {c, c1} = gated_agent!("say thanks", %{"action_class" => "comment"})
      :processing = Custode.approve_action(c, c1, via: :cli)

      # decided, but it never said what it was
      {d, d1} = gated_agent!("prune", %{})
      :processing = Custode.approve_action(d, d1, via: :cli)

      assert [
               %{class: "comment", risk: nil, approved: 1, rejected: 0, rate: 1.0},
               %{class: "implement", risk: nil, approved: 1, rejected: 1, rate: 0.5}
             ] = Gates.approval_rates_by_class()

      assert Enum.all?(Gates.approval_rates_by_class(), &is_float(&1.median_wait_min))
    end
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
