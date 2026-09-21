defmodule Custode.Operator.ActionsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import ObanClaude.Testing

  alias Custode.Asks
  alias Custode.Operator.Actions
  alias Custode.Repo
  alias ObanClaude.Agent

  setup do
    path = Path.join(System.tmp_dir!(), uid("actions") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    on_exit(fn -> Repo.query!("DELETE FROM asks") end)
    :ok
  end

  defp ticks_for(agent_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "ObanClaude.Agent.Tick",
        where: fragment("json_extract(?, '$.agent_id')", j.args) == ^agent_id
      )
    )
  end

  describe "message/3: there is no state in which a message vanishes" do
    test "an idle agent takes it as a prompt" do
      id = start_stub_agent!()

      assert {:ok, :delivered} = Actions.message(id, "what changed on main?")
      assert_receive {:enqueued, args, _meta}, 1_000
      assert args["prompt"] =~ "what changed on main?"
    end

    # the engine answers :agent_not_running for an offline agent, which is why
    # the agent page hid its composer. A routine can be started with the
    # message as its turn's prompt instead.
    test "an OFFLINE routine is started with the message as the turn's prompt" do
      routine = routine_fixture!(tmp_workspace!())

      assert {:ok, :started} = Actions.message(routine.id, "look at issue 42 first")

      assert [tick] = ticks_for(routine.id)
      assert tick.args["prompt"] == "look at issue 42 first"
      assert tick.args["if_offline"] == "start"
      assert tick.queue == "ticks"
    end

    test "an offline id with no routine cannot be started, and says so" do
      assert {:error, :agent_not_running} = Actions.message(uid("ghost"), "hello")
    end

    # the engine DROPS a prompt cast at a paused agent
    test "a PAUSED agent is resumed first, so the message is not dropped" do
      id = start_stub_agent!()
      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      assert {:ok, :resumed} = Actions.message(id, "carry on with the release")

      assert_receive {:enqueued, args, _meta}, 1_000
      assert args["prompt"] =~ "carry on with the release"
    end

    test "blank text is not a message" do
      assert {:error, :empty} = Actions.message(start_stub_agent!(), "   ")
    end
  end

  describe "dismiss_ask/2" do
    test "closes an ask with an optional reason" do
      {:ok, first} = Asks.ask(uid("asker"), "is this still blocked?")
      assert :ok = Actions.dismiss_ask(first.id)
      assert %{status: "dismissed", dismissal_reason: nil} = Asks.get(first.id)

      {:ok, second} = Asks.ask(uid("asker"), "did the token get fixed?")
      assert :ok = Actions.dismiss_ask(second.id, "fixed on the host")

      assert %{status: "dismissed", dismissal_reason: "fixed on the host"} = Asks.get(second.id)
    end

    test "returns a closed ask's error without pretending to dismiss it again" do
      {:ok, ask} = Asks.ask(uid("asker"), "still relevant?")
      assert :ok = Actions.dismiss_ask(ask.id)
      assert {:error, reason} = Actions.dismiss_ask(ask.id)
      assert reason =~ "already dismissed"
    end
  end

  test "beat on an id with no routine is an error, not a crash" do
    assert {:error, :no_routine} = Actions.beat(uid("no-such-routine"))
  end

  describe "the caretaker" do
    test "is the routine tagged :meta, and tell_custode reaches it" do
      workspace = tmp_workspace!()
      # oban_jobs is shared across the suite: a fixed id collides with every
      # other test that beats a caretaker
      caretaker = uid("caretaker")

      put_env!(:routines, [
        %{id: uid("worker"), cron: "@daily", workspace: workspace, prompt: "sweep"},
        %{id: caretaker, cron: "@daily", workspace: workspace, prompt: "sweep", tags: [:meta]}
      ])

      assert Actions.caretaker() == caretaker
      assert {:ok, :started} = Actions.tell_custode("what needs me today?")
      assert [tick] = ticks_for(caretaker)
      assert tick.args["prompt"] == "what needs me today?"
    end

    test "a roster with no caretaker says so" do
      put_env!(:routines, [])
      assert Actions.caretaker() == nil
      assert {:error, :no_caretaker} = Actions.tell_custode("hello")
    end
  end

  describe "run/4 carries out a signal's own op" do
    defp gated!(action) do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => action})
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(id, :awaiting_permission, 1_000)

      eventually(fn -> assert [_gate] = Custode.Gates.open_gates(id) end)
      {id, action_id}
    end

    test "approve and reject reach the gate row with the surface that decided" do
      {approved, a1} = gated!("open a draft PR")
      assert :ok = Actions.run(:approve, %{agent: approved, action: a1}, %{}, via: :liveview)

      {rejected, a2} = gated!("force-push main")

      assert :ok =
               Actions.run(
                 :reject,
                 %{agent: rejected, action: a2},
                 %{"reason" => "never force-push", "one_off" => "true"},
                 via: :liveview
               )

      gate = Repo.one!(from(g in Custode.Gates.Gate, where: g.agent_id == ^rejected))
      assert gate.outcome == "rejected"
      assert gate.reason == "never force-push"
      assert gate.decided_via == "liveview"
    end

    test "dismissal requires the ask id the operator actually saw" do
      {:ok, first} = Asks.ask(uid("asker"), "old question?")
      {:ok, current} = Asks.ask(uid("asker"), "current question?")
      assert :ok = Actions.dismiss_ask(first.id)

      assert {:error, reason} =
               Actions.run(:dismiss_ask, %{ask: current.id}, %{"ask_id" => to_string(first.id)})

      assert reason =~ "no longer pending"
      assert {:error, _reason} = Actions.run(:dismiss_ask, %{ask: current.id})
      assert Asks.get(current.id).status == "open"

      assert :ok =
               Actions.run(:dismiss_ask, %{ask: current.id}, %{
                 "ask_id" => to_string(current.id),
                 "reason" => "already resolved"
               })

      assert Asks.get(current.id).dismissal_reason == "already resolved"
      assert Actions.handles?(:dismiss_ask)
    end

    test "answering a parked agent is a message" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "ask_user", "question" => "staging or prod?"})
        )

      {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)

      assert :ok = Actions.run(:answer, %{agent: id}, %{"text" => "staging"}, via: :liveview)
      assert_receive {:enqueued, args, _meta}, 1_000
      assert args["prompt"] =~ "staging"
    end

    test "an op no surface can carry out here is refused, not faked (#449)" do
      assert {:error, {:unhandled_op, :open_agent}} = Actions.run(:open_agent, %{agent: "x"})
      refute Actions.handles?(:open_agent)
      refute Actions.handles?(:set_rail)
      assert Actions.handles?(:approve)
    end
  end
end
