defmodule Custode.GatesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Feed.Ingest
  alias Custode.Gates
  alias ObanClaude.Agent

  doctest Custode.Gates.Class

  test "gates open from transitions with their payload, and resolve on exit" do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "x")

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => "prune"})
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

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => action})
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

    test "a stale durable gate is requeued instead of resolving a fresh live gate" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{on_note: :ignore})
      test_pid = self()

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            send(test_pid, {:enqueued, args, meta})
            {:ok, :queued}
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      stale =
        Custode.Repo.insert!(%Gates.Gate{
          agent_id: routine.id,
          kind: "approval",
          action_id: "act_old_generation",
          detail: "old process action"
        })

      :processing = Agent.submit_prompt(routine.id, "x")
      assert_receive {:enqueued, _args, turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "fresh action"})
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)

      stale
      |> Ecto.Changeset.change(action_id: action_id)
      |> Custode.Repo.update!()

      eventually(fn -> assert length(Gates.open_gates(routine.id)) == 2 end)
      :processing = Custode.approve_action(routine.id, action_id, via: :mcp)

      assert %{status: "requeued", outcome: nil, decided_by: nil} =
               Custode.Repo.get!(Gates.Gate, stale.id)

      assert %{status: "resolved", outcome: "approved", decided_via: "mcp"} =
               Custode.Repo.get_by!(Gates.Gate,
                 action_id: action_id,
                 detail: "fresh action"
               )

      assert File.read!(Path.join([workspace, "inbox", "restart-gate-#{stale.id}.md"])) =~
               "old process action"
    end

    test "offline gate decisions recover once and never record a false decision" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{on_note: :ignore})

      approve =
        Custode.Repo.insert!(%Gates.Gate{
          agent_id: routine.id,
          kind: "approval",
          action_id: "act_crashed_approve",
          detail: "approve after crash",
          decided_by: "operator",
          decided_via: "mcp"
        })

      assert {:error, {:rehydration_required, :requeued, :offline}} =
               Custode.approve_action(routine.id, approve.action_id, via: :mcp)

      assert %{status: "requeued", outcome: nil, decided_by: nil, decided_via: nil} =
               Custode.Repo.get!(Gates.Gate, approve.id)

      assert {:error, {:rehydration_required, "requeued", :offline}} =
               Custode.approve_action(routine.id, approve.action_id, via: :mcp)

      reject =
        Custode.Repo.insert!(%Gates.Gate{
          agent_id: routine.id,
          kind: "approval",
          action_id: "act_crashed_reject",
          detail: "reject after crash"
        })

      assert {:error, {:rehydration_required, :requeued, :offline}} =
               Custode.reject_with_note(routine.id, reject.action_id, "no", via: :mcp)

      assert %{status: "requeued", outcome: nil, reason: nil} =
               Custode.Repo.get!(Gates.Gate, reject.id)

      assert length(Path.wildcard(Path.join([workspace, "inbox", "restart-gate-*.md"]))) == 2
    end

    test "a provider crash during approval becomes a recoverable domain error" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{on_note: :ignore})
      test_pid = self()
      enqueues = :atomics.new(1, [])

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            case :atomics.add_get(enqueues, 1, 1) do
              1 ->
                send(test_pid, {:enqueued, args, meta})
                {:ok, :queued}

              _continuation ->
                raise "queue unavailable"
            end
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      :processing = Agent.submit_prompt(routine.id, "x")
      assert_receive {:enqueued, _args, turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "ship it"})
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)

      eventually(fn -> assert [_gate] = Gates.open_gates(routine.id) end)

      log =
        capture_log(fn ->
          assert {:error, {:decision_failed, :requeued, :provider_exited}} =
                   Custode.approve_action(routine.id, action_id, via: :mcp)
        end)

      assert log =~ "queue unavailable"

      assert %{status: "requeued", outcome: nil, decided_by: nil} =
               Custode.Repo.get_by!(Gates.Gate, action_id: action_id)

      assert File.read!(
               Path.join([workspace, "inbox", "restart-gate-#{gate_for(routine.id).id}.md"])
             ) =~ "ship it"
    end

    test "an enqueue refusal keeps the live gate open and retryable" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{on_note: :ignore})
      test_pid = self()
      enqueues = :atomics.new(1, [])

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn args, meta ->
            case :atomics.add_get(enqueues, 1, 1) do
              1 ->
                send(test_pid, {:enqueued, args, meta})
                {:ok, :queued}

              2 ->
                {:error, :queue_unavailable}

              3 ->
                send(test_pid, {:approved_enqueued, args, meta})
                {:ok, :queued}
            end
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      :processing = Agent.submit_prompt(routine.id, "x")
      assert_receive {:enqueued, _args, turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "retry me"})
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)

      eventually(fn -> assert [_gate] = Gates.open_gates(routine.id) end)

      assert {:error, {:decision_retryable, {:error, {:enqueue_failed, :queue_unavailable}}}} =
               Custode.approve_action(routine.id, action_id, via: :mcp)

      assert {:ok, {:awaiting_permission, %{id: ^action_id}}} = Agent.status(routine.id)

      assert %{status: "open", outcome: nil, decided_by: nil, decided_via: nil} =
               Custode.Repo.get_by!(Gates.Gate, action_id: action_id)

      assert :processing = Custode.approve_action(routine.id, action_id, via: :mcp)
      assert_receive {:approved_enqueued, %{"prompt" => "Approved: retry me" <> _rest}, _meta}
    end

    test "retries distinguish already applied decisions without a second continuation" do
      {approved_id, approved_action} = gated_agent!("ship once")
      :processing = Custode.approve_action(approved_id, approved_action, via: :mcp)
      assert_receive {:enqueued, _args, _meta}

      assert {:already_applied, :approved} =
               Custode.approve_action(approved_id, approved_action, via: :mcp)

      refute_receive {:enqueued, _args, _meta}, 50

      {rejected_id, rejected_action} = gated_agent!("reject once")
      :rejected = Custode.reject_with_note(rejected_id, rejected_action, "no", via: :mcp)

      assert {:already_applied, :rejected} =
               Custode.reject_with_note(rejected_id, rejected_action, "no", via: :mcp)

      assert Custode.approve_action(rejected_id, rejected_action, via: :mcp) ==
               {:error, {:already_decided, "rejected"}}
    end

    test "concurrent stale retries create one recovery notice" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{on_note: :ignore})

      gate =
        Custode.Repo.insert!(%Gates.Gate{
          agent_id: routine.id,
          kind: "approval",
          action_id: "act_concurrent",
          detail: "recover exactly once"
        })

      results =
        1..2
        |> Task.async_stream(fn _ -> Gates.recover(routine.id, gate.action_id) end,
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert {:ok, :requeued} in results
      assert {:ok, {:already, "requeued", nil}} in results

      notes = Custode.Feed.recent_by_event("inbox_note", agent: routine.id, limit: 10)
      assert Enum.count(notes, &(&1["summary"] =~ "restart-gate-#{gate.id}.md")) == 1
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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        Ingest.handle_event(
          [:oban_claude, :run, :stop],
          %{cost_usd: 0.0},
          %{result: result, job: %{meta: turn_meta}},
          nil
        )

      :ok = finish_agent_turn(turn_meta, result)

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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        Ingest.handle_event(
          [:oban_claude, :run, :stop],
          %{cost_usd: 0.0},
          %{result: silent, job: %{meta: turn_meta}},
          nil
        )

      :ok = finish_agent_turn(turn_meta, silent)
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

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "ask_user", "question" => "which env?"})
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

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok =
      finish_agent_turn(
        turn_meta,
        structured_result(%{"directive" => "request_permission", "action" => "prune"})
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
