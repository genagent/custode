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
      on_exit(fn -> Agent.stop_agent(routine.id) end)

      assert {:ok, :started} = Actions.message(routine.id, "look at issue 42 first")

      [turn] =
        eventually(fn ->
          assert [turn] =
                   jobs_for("ObanClaude.Agent.Job")
                   |> Enum.filter(&(&1.meta["agent_id"] == routine.id))

          [turn]
        end)

      assert turn.args["prompt"] == "look at issue 42 first"
      assert turn.meta["arc_id"] =~ "operator:"
      assert turn.queue == "agents"
    end

    test "an OFFLINE routine's first gate remains approvable through the real queue" do
      routine =
        routine_fixture!(tmp_workspace!(), %{
          approved_args: %{
            "effort" => "high",
            "model" => "opus",
            "permission_mode" => "bypass_permissions",
            "worktree" => "custode-#{uid("worktree")}"
          }
        })

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      assert {:ok, :started} = Actions.message(routine.id, "prepare issue 42")

      [turn] =
        eventually(fn ->
          assert [turn] =
                   jobs_for("ObanClaude.Agent.Job")
                   |> Enum.filter(&(&1.meta["agent_id"] == routine.id))

          [turn]
        end)

      :ok =
        finish_agent_turn(
          turn.meta,
          structured_result(
            %{
              "directive" => "request_permission",
              "action" => "implement issue 42"
            },
            session_id: "session-issue-42"
          )
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)

      assert :ok = Actions.approve(routine.id, action_id, via: :mcp)
      assert {:ok, :running} = Agent.await(routine.id, :running, 1_000)

      assert [_first, approved] =
               jobs_for("ObanClaude.Agent.Job")
               |> Enum.filter(&(&1.meta["agent_id"] == routine.id))

      assert approved.args["prompt"] =~ "Approved: implement issue 42"
      assert approved.args["worktree"] =~ "custode-worktree-"
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

      [turn] =
        eventually(fn ->
          assert [turn] =
                   jobs_for("ObanClaude.Agent.Job")
                   |> Enum.filter(&(&1.meta["agent_id"] == caretaker))

          [turn]
        end)

      assert turn.args["prompt"] == "what needs me today?"
      assert turn.meta["arc_id"] =~ "operator:"
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
      assert Actions.handles?(:recover_gate)
    end
  end

  describe "shared fleet authority" do
    test "the caretaker has the bounded bundle; specialists and temporary agents do not" do
      workspace = tmp_workspace!()
      target_id = uid("target")
      caretaker_id = uid("caretaker")
      specialist_id = uid("specialist")

      put_env!(:routines, [
        %{id: target_id, cron: "@daily", workspace: workspace, prompt: "sweep"},
        %{
          id: caretaker_id,
          cron: "@daily",
          workspace: workspace,
          prompt: "sweep",
          role: :caretaker
        },
        %{
          id: specialist_id,
          cron: "@daily",
          workspace: workspace,
          prompt: "sweep",
          role: :specialist
        }
      ])

      caretaker_opts = [actor: %{kind: :routine, id: caretaker_id}, via: :mcp]
      specialist_opts = [actor: %{kind: :routine, id: specialist_id}, via: :mcp]
      temporary_opts = [actor: %{kind: :sub_agent, id: uid("temporary")}, via: :mcp]

      assert {:error, reason} = Actions.beat(target_id, specialist_opts)
      assert reason =~ "caretaker role"
      assert ticks_for(target_id) == []

      assert {:error, reason} =
               Actions.drop_note(target_id, "denied.md", "no", temporary_opts)

      assert reason =~ "caretaker role"
      refute File.exists?(Path.join([workspace, "inbox", "denied.md"]))

      assert :ok = Actions.beat(target_id, caretaker_opts)
      assert [_tick] = ticks_for(target_id)

      assert {:ok, path} = Actions.drop_note(target_id, "allowed.md", "yes", caretaker_opts)
      assert File.read!(path) == "yes"
    end

    test "denied resume, presence, and drain calls do not change state" do
      workspace = tmp_workspace!()
      caretaker_id = uid("caretaker")
      specialist_id = uid("specialist")

      put_env!(:routines, [
        %{
          id: caretaker_id,
          cron: "@daily",
          workspace: workspace,
          prompt: "sweep",
          role: :caretaker
        },
        %{
          id: specialist_id,
          cron: "@daily",
          workspace: workspace,
          prompt: "sweep",
          role: :specialist
        }
      ])

      target = start_stub_agent!()
      :ok = Agent.emergency_pause(target)
      {:ok, :paused} = Agent.await(target, :paused, 1_000)

      specialist_opts = [actor: %{kind: :routine, id: specialist_id}, via: :mcp]
      caretaker_opts = [actor: %{kind: :routine, id: caretaker_id}, via: :mcp]

      assert {:error, reason} = Actions.resume(target, specialist_opts)
      assert reason =~ "caretaker role"
      assert {:ok, :paused} = Agent.status(target)

      put_env!(:presence_override, :away)
      assert {:error, reason} = Actions.set_presence(:present, caretaker_opts)
      assert reason =~ "human operator"
      assert Application.get_env(:custode, :presence_override) == :away

      parent = self()

      assert {:error, reason} =
               Actions.drain(
                 caretaker_opts ++
                   [queues: [:ticks], pause: fn _queue -> send(parent, :paused_queue) end]
               )

      assert reason =~ "human operator"
      refute_received :paused_queue

      assert :ok = Actions.resume(target, caretaker_opts)
      assert {:ok, :idle} = Agent.await(target, :idle, 1_000)
    end
  end
end
