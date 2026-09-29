defmodule Custode.AgentHandoffTest do
  use ExUnit.Case, async: false

  alias Custode.AgentHandoff

  setup do
    id = "handoff-#{System.unique_integer([:positive])}"

    {:ok, runtime} =
      Agent.start_link(fn ->
        %{
          routines: %{},
          authorization_snapshots: %{},
          live: %{},
          active_turns: MapSet.new(),
          active_turn_revisions: %{},
          pause_intents: %{},
          cleared_absent_pause_intents: [],
          active_message_targets: [],
          message_reconcile_order: [],
          settled_removed: [],
          queued: MapSet.new(),
          calls: [],
          fence_result: {:ok, %{cancelled: [], executing: []}},
          pause_results: [],
          replay_result: :ok
        }
      end)

    handler_id = "custode-agent-handoff-test-#{System.unique_integer([:positive])}"

    {:ok, coordinator} =
      start_supervised(
        {AgentHandoff,
         name: nil,
         handler_id: handler_id,
         poll_interval: 25,
         stop_timeout: 100,
         dependencies: dependencies(runtime)}
      )

    # Initialization performs the empty boot reconciliation synchronously.
    assert :ready = AgentHandoff.status(coordinator, "scan-barrier")

    %{id: id, runtime: runtime, coordinator: coordinator}
  end

  test "compatible and offline routines do not touch a provider", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")

    assert :ok = AgentHandoff.ensure(coordinator, id)
    assert calls(runtime) == []

    put_live(runtime, id, :claude, :idle, "r1")

    assert :ok = AgentHandoff.ensure(coordinator, id)
    assert calls(runtime) == [{:info, id, :claude}]
  end

  test "a compatible idle agent applies a durable pause intent before becoming ready", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    put_live(runtime, id, :claude, :idle, "r1")
    put_pause_intent(runtime, id, %{cause: :emergency_pause, reason: :operator})

    assert :ok = AgentHandoff.ensure(coordinator, id)
    assert %{state: :paused} = live(runtime, id)
    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == nil

    assert Enum.any?(calls(runtime), fn
             {:emergency_pause, ^id, :claude, %{cause: :emergency_pause, reason: :operator}} ->
               true

             _other ->
               false
           end)

    assert %{pause_context: %{cause: :emergency_pause, reason: :operator}} = live(runtime, id)
  end

  test "a persisted pause restores its provider provenance enum", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    put_live(runtime, id, :claude, :idle, "r1")

    put_pause_intent(runtime, id, %{
      "cause" => "pause_after_turn",
      "reason" => "daily token rail hit"
    })

    assert :ok = AgentHandoff.ensure(coordinator, id)

    assert Enum.any?(calls(runtime), fn
             {:emergency_pause, ^id, :claude,
              %{"reason" => "daily token rail hit", cause: :pause_after_turn}} ->
               true

             _other ->
               false
           end)
  end

  test "a compatible paused agent clears an already applied durable intent", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")

    put_live(runtime, id, :claude, :paused, "r1",
      pause_context: %{cause: :emergency_pause, reason: :operator}
    )

    put_pause_intent(runtime, id, %{cause: :emergency_pause, reason: :operator})

    assert :ok = AgentHandoff.ensure(coordinator, id)
    assert :ready = AgentHandoff.status(coordinator, id)
    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == nil
    refute Enum.any?(calls(runtime), &match?({:emergency_pause, ^id, _provider, _context}, &1))
  end

  test "a durable turn-boundary pause waits for its provider latch", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :codex, "r1")
    put_live(runtime, id, :codex, :running, "r1")
    parent = self()
    pause_context = %{cause: :pause_after_turn, reason: :spend_rail}

    assert :ok =
             AgentHandoff.pause(coordinator, id, pause_context, fn ->
               intent = Agent.get(runtime, &get_in(&1, [:pause_intents, id]))
               send(parent, {:durable_before_provider, intent})

               Agent.update(runtime, fn state ->
                 put_in(state, [:live, id, :deferred_pause], pause_context)
               end)

               :ok
             end)

    assert_receive {:durable_before_provider, ^pause_context}
    Process.sleep(40)
    assert {:pending, %{phase: :preserving}} = AgentHandoff.status(coordinator, id)
    refute Enum.any?(calls(runtime), &match?({:emergency_pause, ^id, _provider, _context}, &1))

    set_state(runtime, id, :paused)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == nil
  end

  test "a failed emergency pause retains preservation ownership and never replays first",
       context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    put_live(runtime, id, :claude, :idle, "r1")
    set_queued(runtime, id)
    set_pause_results(runtime, [{:error, :temporarily_unavailable}, :ok])

    assert {:error, :temporarily_unavailable} =
             AgentHandoff.pause(
               coordinator,
               id,
               %{cause: :emergency_pause, reason: :operator},
               fn -> fake_pause(runtime, id, :claude) end
             )

    assert {:pending, %{phase: :preserving}} = AgentHandoff.status(coordinator, id)
    refute Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))

    assert_eventually(fn ->
      match?({:pending, %{phase: :preserved}}, AgentHandoff.status(coordinator, id))
    end)

    assert %{state: :paused} = live(runtime, id)
    refute Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))

    assert Enum.count(
             calls(runtime),
             &match?({:emergency_pause, ^id, :claude, _context}, &1)
           ) == 2
  end

  test "the current durable queue head is admitted directly while offline", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    set_queued(runtime, id)

    assert :submitted =
             AgentHandoff.admit(coordinator, id, fn -> :submitted end, current_queue_head: true)

    refute Enum.any?(calls(runtime), &match?({:start, ^id, _, _, _}, &1))
    refute Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "durable admission does not advance an existing replay and call back twice", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    put_live(runtime, id, :claude, :idle, "r1")
    set_queued(runtime, id)
    Agent.update(runtime, &%{&1 | replay_result: {:deferred, :agent_busy}})

    GenServer.cast(coordinator, {:work_queued, id})

    assert_eventually(fn ->
      match?({:pending, %{phase: :replaying}}, AgentHandoff.status(coordinator, id))
    end)

    Agent.update(runtime, &%{&1 | replay_result: :ok})
    parent = self()

    assert {:deferred, :handoff_pending} =
             AgentHandoff.admit(
               coordinator,
               id,
               fn ->
                 send(parent, :admission_callback)
                 :submitted
               end,
               durable_message: true
             )

    refute_receive :admission_callback
  end

  test "a draining replay fences newer non-durable admission", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r1")
    put_live(runtime, id, :claude, :running, "r1")
    set_queued(runtime, id)

    :sys.replace_state(coordinator, fn state ->
      put_in(state, [:pending, id], %{
        provider: :claude,
        preserve_pause?: false,
        phase: :draining
      })
    end)

    parent = self()

    assert {:deferred, :handoff_pending} =
             AgentHandoff.admit(
               coordinator,
               id,
               fn ->
                 send(parent, :newer_admission)
                 :submitted
               end,
               []
             )

    refute_receive :newer_admission
    assert %{phase: :draining} = :sys.get_state(coordinator).pending[id]
  end

  test "only the durable queue head may lift a preserved pause", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")

    put_live(runtime, id, :claude, :paused, "old",
      deferred_pause: %{cause: :pause_after_turn, reason: :operator}
    )

    set_queued(runtime, id)
    assert :ok = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{phase: :preserved}} = AgentHandoff.status(coordinator, id)
    parent = self()

    callback = fn ->
      send(parent, :admission_callback)
      :submitted
    end

    assert {:deferred, :handoff_pending} =
             AgentHandoff.admit(coordinator, id, callback,
               durable_message: true,
               allow_preserved: true,
               current_queue_head: false
             )

    refute_receive :admission_callback
    assert {:pending, %{phase: :preserved}} = AgentHandoff.status(coordinator, id)

    assert :submitted =
             AgentHandoff.admit(coordinator, id, callback,
               durable_message: true,
               allow_preserved: true,
               current_queue_head: true
             )

    assert_receive :admission_callback
  end

  test "an ad-hoc agent outside the routine roster does not need a config handoff", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_live(runtime, id, :claude, :idle, nil)

    assert :ok = AgentHandoff.ensure(coordinator, id)
    assert calls(runtime) == []
  end

  test "an idle mismatch is replaced before queued messages replay", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")

    put_live(runtime, id, :claude, :idle, "old", session_arcs: %{"default" => "session-1"})

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{phase: :replaying}} = AgentHandoff.status(coordinator, id)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)

    assert %{provider: :claude, state: :idle, revision: "new"} = live(runtime, id)

    assert calls(runtime) == [
             {:info, id, :claude},
             {:quiesce, id, :claude, :config_change},
             {:status, id, :claude},
             {:info, id, :claude},
             {:stop, id, :claude},
             {:await, id, :claude, :offline},
             {:start, id, :claude, "new", %{}},
             {:info, id, :claude},
             {:status, id, :claude},
             {:replay, id},
             {:release_inbox, id}
           ]
  end

  test "a paused provider with physical work drains before replacement", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :paused, "old", quiesce_draining?: true)

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{provider: :claude, phase: :provider_drain}} =
             AgentHandoff.status(coordinator, id)

    refute Enum.any?(calls(runtime), &match?({:stop, ^id, :claude}, &1))

    set_quiesce_draining(runtime, id, false)
    assert :ok = AgentHandoff.reconcile(coordinator, id)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)

    assert %{provider: :claude, state: :paused, revision: "new"} = live(runtime, id)
    assert Enum.any?(calls(runtime), &match?({:stop, ^id, :claude}, &1))
  end

  test "running work is fenced and the latest of several edits wins", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "r2")
    put_live(runtime, id, :claude, :running, "r1")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{provider: :claude, preserve_pause?: false, phase: :quiescing}} =
             AgentHandoff.status(coordinator, id)

    # The first change is never started. The coordinator reads the roster
    # again only after the old turn reaches its safe boundary.
    put_routine(runtime, id, :claude, "r3")
    assert :ok = AgentHandoff.reconcile(coordinator, id)
    set_state(runtime, id, :paused)

    AgentHandoff.handle_transition(
      [:oban_claude, :agent, :transition],
      %{},
      %{agent_id: id, from: :running, to: :paused},
      coordinator
    )

    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{revision: "r3", state: :idle} = live(runtime, id)

    starts = Enum.filter(calls(runtime), &match?({:start, ^id, _, _, _}, &1))
    assert [{:start, ^id, :claude, "r3", %{}}] = starts
  end

  test "reverting a running handoff retains and replays queued work", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(coordinator, id)

    set_queued(runtime, id)
    put_routine(runtime, id, :claude, "old")
    set_state(runtime, id, :paused)

    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{revision: "old", state: :idle} = live(runtime, id)
    assert Enum.any?(calls(runtime), &match?({:resume, ^id, :claude}, &1))
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "a gate remains live until its one continuation settles", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :codex, "new")

    put_live(
      runtime,
      id,
      :codex,
      {:awaiting_permission, %{id: "gate-1", description: "ship it"}},
      "old"
    )

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)

    assert %{
             state: {:awaiting_permission, %{id: "gate-1"}},
             deferred_pause: %{reason: :config_change}
           } = live(runtime, id)

    refute Enum.any?(calls(runtime), &match?({:stop, ^id, _}, &1))

    # The provider owns the gate. Approval/answer runs there and only its
    # terminal transition permits replacement.
    set_state(runtime, id, :running)
    Process.sleep(25)
    refute Enum.any?(calls(runtime), &match?({:stop, ^id, _}, &1))

    set_state(runtime, id, :paused)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{revision: "new", state: :idle} = live(runtime, id)
  end

  test "a non-config pause survives replacement and queued work stays durable", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")

    put_live(runtime, id, :claude, :paused, "old",
      # The reason alone does not grant ownership to this coordinator.
      deferred_pause: %{cause: :pause_after_turn, reason: :config_change}
    )

    set_queued(runtime, id)

    assert :ok = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{phase: :preserved, preserve_pause?: true}} =
             AgentHandoff.status(coordinator, id)

    assert %{
             revision: "new",
             state: :paused,
             pause_context: %{cause: :pause_after_turn, reason: :config_change}
           } = live(runtime, id)

    assert Enum.any?(calls(runtime), fn
             {:emergency_pause, ^id, :claude, %{cause: :pause_after_turn, reason: :config_change}} ->
               true

             _other ->
               false
           end)

    refute Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))

    set_state(runtime, id, :idle)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "a crash in the stop-start window cannot lose a non-config pause", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")

    put_live(runtime, id, :claude, :paused, "old",
      pause_context: %{cause: :emergency_pause, reason: :operator}
    )

    set_active_turn(runtime, id, true)

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)

    assert {:pending, %{phase: :physical_wait, preserve_pause?: true}} =
             AgentHandoff.status(coordinator, id)

    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == %{
             cause: :emergency_pause,
             reason: :operator
           }

    assert live(runtime, id) == nil
    assert :ok = stop_supervised(AgentHandoff)
    set_active_turn(runtime, id, false)

    handler_id = "custode-agent-handoff-pause-recovery-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:pause_recovery, id}
        )
      )

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)

    assert %{
             provider: :claude,
             revision: "new",
             state: :paused,
             pause_context: %{cause: :emergency_pause, reason: :operator}
           } = live(runtime, id)

    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == nil
  end

  test "a mismatched process never seeds the replacement with stale sessions", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :codex, "codex-r1")

    put_live(runtime, id, :claude, :idle, "claude-r1",
      session_arcs: %{"default" => "claude-session"}
    )

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{provider: :codex, revision: "codex-r1", session_arcs: %{}} = live(runtime, id)

    assert Enum.any?(calls(runtime), fn
             {:start, ^id, :codex, "codex-r1", %{}} -> true
             _other -> false
           end)
  end

  test "a replacement starts with the current routine's compatible arc seeds", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    seeds = %{"default" => "current-session", "review" => "review-session"}
    put_routine(runtime, id, :codex, "codex-r2", seeds)
    put_live(runtime, id, :codex, :idle, "codex-r1", session_arcs: %{"default" => "stale"})

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)

    assert Enum.any?(calls(runtime), fn
             {:start, ^id, :codex, "codex-r2", ^seeds} -> true
             _other -> false
           end)

    assert %{session_arcs: ^seeds} = live(runtime, id)
  end

  test "startup scanning recovers a config handoff after coordinator death", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :claude, "new")

    put_live(runtime, id, :claude, :paused, "old",
      deferred_pause: %{cause: :quiesce, reason: :config_change}
    )

    handler_id = "custode-agent-handoff-restart-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:recovered_handoff, id}
        )
      )

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)
    assert %{revision: "new", state: :idle} = live(runtime, id)
    refute Enum.any?(calls(runtime), &match?({:emergency_pause, ^id, _, _context}, &1))
  end

  test "startup resumes a compatible process paused by a reverted config handoff", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :claude, "current")

    put_live(runtime, id, :claude, :paused, "current",
      pause_context: %{cause: :quiesce, reason: :config_change}
    )

    set_queued(runtime, id)
    handler_id = "custode-agent-handoff-reverted-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:reverted_handoff, id}
        )
      )

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)
    assert %{revision: "current", state: :idle} = live(runtime, id)
    assert Enum.any?(calls(runtime), &match?({:resume, ^id, :claude}, &1))
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "startup scanning finishes replay after a compatible replacement", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :claude, "current")
    put_live(runtime, id, :claude, :idle, "current")
    set_queued(runtime, id)

    handler_id = "custode-agent-handoff-replay-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:recovered_replay, id}
        )
      )

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
    refute Enum.any?(calls(runtime), &match?({:stop, ^id, _}, &1))
  end

  test "startup scanning starts an offline routine that has deferred messages", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :codex, "current")
    set_queued(runtime, id)

    handler_id = "custode-agent-handoff-offline-replay-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:recovered_offline_replay, id}
        )
      )

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)
    assert %{provider: :codex, revision: "current", state: :idle} = live(runtime, id)
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "a compatible replacement paused before replay retains ownership until resume", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :claude, "current")
    put_live(runtime, id, :claude, :paused, "current")
    set_queued(runtime, id)

    handler_id = "custode-agent-handoff-paused-replay-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:recovered_paused_replay, id}
        )
      )

    assert_eventually(fn ->
      match?({:pending, %{phase: :preserved}}, AgentHandoff.status(recovered, id))
    end)

    refute Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
    set_state(runtime, id, :idle)

    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)
    assert Enum.any?(calls(runtime), &match?({:replay, ^id}, &1))
  end

  test "polling recovers when the old process dies without transition telemetry", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    drop_live(runtime, id)

    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{revision: "new", state: :idle} = live(runtime, id)
    assert Enum.any?(calls(runtime), &match?({:start, ^id, :claude, "new", _}, &1))
  end

  test "an offline registry waits for the old durable provider turn", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :codex, "current")
    set_queued(runtime, id)
    set_active_turn(runtime, id, true)

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :physical_wait}} = AgentHandoff.status(coordinator, id)
    refute Enum.any?(calls(runtime), &match?({:start, ^id, _, _, _}, &1))

    set_active_turn(runtime, id, false)

    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert %{provider: :codex, revision: "current", state: :idle} = live(runtime, id)
  end

  test "a failed durable replay keeps the delivery fence closed for retry", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :idle, "old")
    Agent.update(runtime, &%{&1 | replay_result: {:error, :temporarily_unavailable}})

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    Process.sleep(40)
    assert {:pending, %{phase: :replaying}} = AgentHandoff.status(coordinator, id)

    Agent.update(runtime, &%{&1 | replay_result: :ok})
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)

    assert Enum.count(calls(runtime), &match?({:replay, ^id}, &1)) >= 2
  end

  test "provider admission invokes only the exact current execution contract", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "current")
    Agent.update(runtime, &put_in(&1, [:routines, id, :delivery_revision], "delivery-current"))
    parent = self()

    deliver = fn ->
      send(parent, :delivered)
      :submitted
    end

    assert :submitted =
             AgentHandoff.admit(coordinator, id, deliver,
               expected_provider: :claude,
               expected_revision: "current"
             )

    assert_receive :delivered

    assert :submitted =
             AgentHandoff.admit(coordinator, id, deliver,
               expected_provider: :claude,
               expected_delivery_revision: "delivery-current"
             )

    assert_receive :delivered

    assert {:error,
            {:stale_execution_config,
             %{expected_provider: :claude, expected_delivery_revision: "delivery-old"},
             %{provider: :claude, delivery_revision: "delivery-current"}}} =
             AgentHandoff.admit(coordinator, id, deliver,
               expected_provider: :claude,
               expected_delivery_revision: "delivery-old"
             )

    assert {:error,
            {:stale_execution_config, %{expected_provider: :claude, expected_revision: "old"},
             %{provider: :claude, revision: "current"}}} =
             AgentHandoff.admit(coordinator, id, deliver,
               expected_provider: :claude,
               expected_revision: "old"
             )

    assert {:error,
            {:stale_execution_config, %{expected_provider: :codex, expected_revision: "current"},
             %{provider: :claude, revision: "current"}}} =
             AgentHandoff.admit(coordinator, id, deliver,
               expected_provider: :codex,
               expected_revision: "current"
             )

    assert {:error, :invalid_expected_execution_config} =
             AgentHandoff.admit(coordinator, id, deliver, expected_provider: :claude)

    refute_receive :delivered
  end

  test "reconfigure applies its callback before reconciling every target", context do
    %{id: first_id, runtime: runtime, coordinator: coordinator} = context
    second_id = "#{first_id}-second"
    put_routine(runtime, first_id, :claude, "old-first")
    put_routine(runtime, second_id, :codex, "old-second")
    put_live(runtime, first_id, :claude, :idle, "old-first")
    put_live(runtime, second_id, :codex, :idle, "old-second")

    assert {:ok, :written} =
             AgentHandoff.reconfigure(coordinator, [first_id, second_id], fn ->
               record(runtime, {:config_write, [first_id, second_id]})
               put_routine(runtime, first_id, :claude, "new-first")
               put_routine(runtime, second_id, :codex, "new-second")
               {:ok, :written}
             end)

    assert replaying_or_ready?(AgentHandoff.status(coordinator, first_id))
    assert replaying_or_ready?(AgentHandoff.status(coordinator, second_id))
    assert %{revision: "new-first", provider: :claude} = live(runtime, first_id)
    assert %{revision: "new-second", provider: :codex} = live(runtime, second_id)

    assert [
             {:config_write, [^first_id, ^second_id]},
             {:info, ^first_id, :claude}
             | _rest
           ] = calls(runtime)

    assert Enum.any?(calls(runtime), &match?({:start, ^first_id, :claude, "new-first", %{}}, &1))

    assert Enum.any?(
             calls(runtime),
             &match?({:start, ^second_id, :codex, "new-second", %{}}, &1)
           )

    assert_eventually(fn -> AgentHandoff.status(coordinator, first_id) == :ready end)
    assert_eventually(fn -> AgentHandoff.status(coordinator, second_id) == :ready end)
  end

  test "reconfigure reconciles targets selected inside its serialized callback", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_live(runtime, id, :claude, :idle, "old")

    assert {:ok, :written} =
             AgentHandoff.reconfigure(coordinator, [], fn ->
               put_routine(runtime, id, :claude, "new")
               {:ok, :written, [id]}
             end)

    assert %{revision: "new", provider: :claude} = live(runtime, id)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
  end

  test "admission queued behind reconfigure observes only the new desired state", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    parent = self()
    put_routine(runtime, id, :claude, "stable")
    put_live(runtime, id, :claude, :idle, "stable")

    Agent.update(runtime, &put_in(&1, [:routines, id, :delivery_revision], "delivery-old"))

    reconfigure =
      Task.async(fn ->
        AgentHandoff.reconfigure(coordinator, [id], fn ->
          send(parent, :reconfigure_callback_waiting)

          receive do
            :finish_reconfigure ->
              Agent.update(
                runtime,
                &put_in(&1, [:routines, id, :delivery_revision], "delivery-new")
              )

              {:ok, :written}
          end
        end)
      end)

    assert_receive :reconfigure_callback_waiting

    admission =
      Task.async(fn ->
        send(parent, :calling_admission)

        AgentHandoff.admit(
          coordinator,
          id,
          fn ->
            revision = Agent.get(runtime, &get_in(&1, [:routines, id, :delivery_revision]))
            send(parent, {:admitted_delivery_revision, revision})
            :submitted
          end,
          expected_provider: :claude,
          expected_delivery_revision: "delivery-new"
        )
      end)

    assert_receive :calling_admission
    assert Task.yield(admission, 20) == nil

    send(coordinator, :finish_reconfigure)

    assert {:ok, :written} = Task.await(reconfigure, 1_000)
    assert :submitted = Task.await(admission, 1_000)
    assert_receive {:admitted_delivery_revision, "delivery-new"}
  end

  test "routine authorization follows the live execution revision across a handoff", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_role(runtime, id, :backlog_worker)
    put_live(runtime, id, :claude, :running, "old")

    assert {:ok, %{execution_revision: "old", role: :backlog_worker}} =
             AgentHandoff.authorization_routine(coordinator, id)

    assert {:ok, :written} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               put_routine(runtime, id, :claude, "new")
               put_role(runtime, id, :caretaker)
               {:ok, :written}
             end)

    assert {:ok, %{execution_revision: "old", role: :backlog_worker}} =
             AgentHandoff.authorization_routine(coordinator, id)

    set_state(runtime, id, :paused)
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)

    assert {:ok, %{execution_revision: "new", role: :caretaker}} =
             AgentHandoff.authorization_routine(coordinator, id)
  end

  test "replayed work gets the replacement authorization while its delivery drains", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_role(runtime, id, :backlog_worker)
    put_live(runtime, id, :claude, :idle, "old")
    set_queued(runtime, id)
    Agent.update(runtime, &%{&1 | replay_result: {:deferred, :agent_busy}})

    assert {:ok, %{execution_revision: "old", role: :backlog_worker}} =
             AgentHandoff.authorization_routine(coordinator, id)

    assert {:ok, :written} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               put_routine(runtime, id, :claude, "new")
               put_role(runtime, id, :caretaker)
               {:ok, :written}
             end)

    assert {:pending, %{phase: :replaying}} = AgentHandoff.status(coordinator, id)
    Agent.update(runtime, &%{&1 | replay_result: :ok})
    assert :ok = AgentHandoff.reconcile(coordinator, id)
    assert %{phase: :draining} = :sys.get_state(coordinator).pending[id]

    assert {:ok, %{execution_revision: "new", role: :caretaker}} =
             AgentHandoff.authorization_routine(coordinator, id)
  end

  test "a restarted coordinator authorizes an active durable turn from its old snapshot",
       context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_role(runtime, id, :backlog_worker)
    put_live(runtime, id, :claude, :running, "old")

    assert {:ok, %{execution_revision: "old"}} =
             AgentHandoff.authorization_routine(coordinator, id)

    put_routine(runtime, id, :claude, "new")
    put_role(runtime, id, :caretaker)
    drop_live(runtime, id)
    set_active_turn(runtime, id, true)
    set_active_turn_revision(runtime, id, "old")

    handler_id = "custode-agent-handoff-auth-restart-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:recovered_authorization, id}
        )
      )

    assert {:ok, %{execution_revision: "old", role: :backlog_worker}} =
             AgentHandoff.authorization_routine(recovered, id)

    set_active_turn(runtime, id, false)
    assert_eventually(fn -> AgentHandoff.status(recovered, id) == :ready end)

    assert {:ok, %{execution_revision: "new", role: :caretaker}} =
             AgentHandoff.authorization_routine(recovered, id)
  end

  test "a removed routine keeps captured authority only while its old turn is active", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_role(runtime, id, :backlog_worker)
    put_live(runtime, id, :claude, :running, "old")

    assert {:ok, %{execution_revision: "old"}} =
             AgentHandoff.authorization_routine(coordinator, id)

    drop_live(runtime, id)
    set_active_turn(runtime, id, true)
    set_active_turn_revision(runtime, id, "old")

    assert {:ok, :removed} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               drop_routine(runtime, id)
               {:ok, :removed}
             end)

    assert {:ok, %{execution_revision: "old", role: :backlog_worker}} =
             AgentHandoff.authorization_routine(coordinator, id)

    set_active_turn(runtime, id, false)

    assert {:error, :unknown_routine} =
             AgentHandoff.authorization_routine(coordinator, id)
  end

  test "ambiguous and legacy durable turns fail authorization closed", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "old")
    put_live(runtime, id, :claude, :idle, "old")

    assert {:ok, %{execution_revision: "old"}} =
             AgentHandoff.authorization_routine(coordinator, id)

    drop_live(runtime, id)
    set_active_turn(runtime, id, true)
    set_active_turn_revisions(runtime, id, ["old", "another-revision"])

    assert {:error, :ambiguous_authorization_revision} =
             AgentHandoff.authorization_routine(coordinator, id)

    set_active_turn_revisions(runtime, id, [nil])

    assert {:error, :missing_authorization_revision} =
             AgentHandoff.authorization_routine(coordinator, id)
  end

  test "a callback error leaves existing handoff ownership intact", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(coordinator, id)

    assert {:error, :write_failed} =
             AgentHandoff.reconfigure(coordinator, [id], fn -> {:error, :write_failed} end)

    assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(coordinator, id)
  end

  test "a callback error still reconciles targets and reports retained failures", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "current")
    set_fence_result(runtime, {:error, :database_unavailable})

    assert {:error,
            {:reconfigure_failed_reconcile_pending, :write_failed,
             [{^id, {:fence_stale_ticks, :database_unavailable}}]}} =
             AgentHandoff.reconfigure(coordinator, [id], fn -> {:error, :write_failed} end)

    assert {:pending, %{phase: :retrying}} = AgentHandoff.status(coordinator, id)
  end

  test "reconfigure reports reconciliation failures and retains retry ownership", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "current")
    set_fence_result(runtime, {:error, :database_unavailable})

    assert {:error,
            {:config_applied_reconcile_pending, :written,
             [{^id, {:fence_stale_ticks, :database_unavailable}}]}} =
             AgentHandoff.reconfigure(coordinator, [id], fn -> {:ok, :written} end)

    assert {:pending, %{phase: :retrying}} = AgentHandoff.status(coordinator, id)
  end

  test "a reconciliation error retains a fail-closed retry owner", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "current")
    set_fence_result(runtime, {:error, :database_unavailable})

    assert {:error, {:fence_stale_ticks, :database_unavailable}} =
             AgentHandoff.reconcile(coordinator, id)

    assert {:pending, %{phase: :retrying}} = AgentHandoff.status(coordinator, id)

    set_fence_result(runtime, {:ok, %{cancelled: [], executing: []}})
    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
  end

  test "routine removal releases a fencing owner", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "current")
    set_fence_result(runtime, {:ok, %{cancelled: [], executing: ["tick-1"]}})

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :fencing}} = AgentHandoff.status(coordinator, id)

    assert {:ok, :removed} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               drop_routine(runtime, id)
               {:ok, :removed}
             end)

    assert :ready = AgentHandoff.status(coordinator, id)
    assert id in Agent.get(runtime, & &1.settled_removed)
  end

  test "routine removal releases a quiesced handoff owner", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(coordinator, id)

    set_state(runtime, id, :paused)

    assert {:ok, :removed} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               drop_routine(runtime, id)
               {:ok, :removed}
             end)

    assert :ready = AgentHandoff.status(coordinator, id)
    assert id in Agent.get(runtime, & &1.settled_removed)
  end

  test "routine removal retries message settlement before releasing the fence", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    assert {:pending, %{phase: :quiescing}} = AgentHandoff.status(coordinator, id)

    set_state(runtime, id, :paused)

    failing = fn _id -> {:error, :database_unavailable} end

    :sys.replace_state(coordinator, fn state ->
      put_in(state, [:dependencies, :settle_removed_messages], failing)
    end)

    assert {:error,
            {:config_applied_reconcile_pending, :removed,
             [{^id, {:settle_removed_messages, :database_unavailable}}]}} =
             AgentHandoff.reconfigure(coordinator, [id], fn ->
               drop_routine(runtime, id)
               {:ok, :removed}
             end)

    assert {:pending, %{phase: :removal_cleanup}} = AgentHandoff.status(coordinator, id)

    succeeding = dependencies(runtime).settle_removed_messages

    :sys.replace_state(coordinator, fn state ->
      put_in(state, [:dependencies, :settle_removed_messages], succeeding)
    end)

    assert_eventually(fn -> AgentHandoff.status(coordinator, id) == :ready end)
    assert id in Agent.get(runtime, & &1.settled_removed)
  end

  test "boot clears an absent routine's pause intent before its id can be reused", context do
    %{id: id, runtime: runtime} = context
    assert :ok = stop_supervised(AgentHandoff)
    put_pause_intent(runtime, id, %{cause: :emergency_pause, reason: :operator})

    handler_id = "custode-agent-handoff-stale-pause-#{System.unique_integer([:positive])}"

    {:ok, recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:stale_pause_recovery, id}
        )
      )

    assert Agent.get(runtime, &get_in(&1, [:pause_intents, id])) == nil
    assert id in Agent.get(runtime, & &1.cleared_absent_pause_intents)

    put_routine(runtime, id, :claude, "reused")
    assert :ok = AgentHandoff.ensure(recovered, id)
    refute Enum.any?(calls(runtime), &match?({:emergency_pause, ^id, _provider, _context}, &1))
  end

  test "boot settles a removed routine's messages before generic reconciliation", context do
    %{id: id, runtime: runtime} = context
    assert :ok = stop_supervised(AgentHandoff)

    Agent.update(runtime, fn state ->
      %{
        state
        | active_message_targets: [id],
          message_reconcile_order: [],
          settled_removed: []
      }
    end)

    handler_id = "custode-agent-handoff-removed-message-#{System.unique_integer([:positive])}"

    {:ok, _recovered} =
      start_supervised(
        Supervisor.child_spec(
          {AgentHandoff,
           name: nil,
           handler_id: handler_id,
           poll_interval: 10,
           stop_timeout: 100,
           dependencies: dependencies(runtime)},
          id: {:removed_message_recovery, id}
        )
      )

    assert Agent.get(runtime, & &1.settled_removed) == [id]

    assert Agent.get(runtime, & &1.message_reconcile_order) == [
             {:settle_removed, id},
             :reconcile
           ]
  end

  test "startup fails closed when durable messages cannot be reconciled", context do
    %{runtime: runtime} = context
    handler_id = "custode-agent-handoff-failed-messages-#{System.unique_integer([:positive])}"
    previous_trap_exit = Process.flag(:trap_exit, true)

    opts = [
      name: nil,
      handler_id: handler_id,
      dependencies:
        Map.put(dependencies(runtime), :reconcile_messages, fn -> {:error, :database_down} end)
    ]

    assert {:error, {:boot_reconciliation_failed, {:messages, :database_down}}} =
             AgentHandoff.start_link(opts)

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "startup fails closed when a removed routine's messages cannot be settled", context do
    %{id: id, runtime: runtime} = context
    handler_id = "custode-agent-handoff-failed-removal-#{System.unique_integer([:positive])}"
    previous_trap_exit = Process.flag(:trap_exit, true)

    Agent.update(runtime, &%{&1 | active_message_targets: [id]})

    dependencies =
      Map.put(dependencies(runtime), :settle_removed_messages, fn ^id ->
        {:error, :database_down}
      end)

    assert {:error,
            {:boot_reconciliation_failed,
             {:removed_messages, ^id, {:settle_removed_messages, :database_down}}}} =
             AgentHandoff.start_link(
               name: nil,
               handler_id: handler_id,
               dependencies: dependencies
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "startup fails closed when one routine cannot be reconciled", context do
    %{id: id, runtime: runtime} = context
    put_routine(runtime, id, :codex, "current")
    set_fence_result(runtime, {:error, :database_unavailable})
    handler_id = "custode-agent-handoff-failed-routine-#{System.unique_integer([:positive])}"
    previous_trap_exit = Process.flag(:trap_exit, true)

    assert {:error,
            {:boot_reconciliation_failed,
             {:routine, ^id, {:fence_stale_ticks, :database_unavailable}}}} =
             AgentHandoff.start_link(
               name: nil,
               handler_id: handler_id,
               dependencies: dependencies(runtime)
             )

    Process.flag(:trap_exit, previous_trap_exit)
  end

  test "the telemetry callback only enqueues coordinator work", context do
    %{id: id, runtime: runtime, coordinator: coordinator} = context
    put_routine(runtime, id, :claude, "new")
    put_live(runtime, id, :claude, :running, "old")

    assert {:deferred, :handoff_pending} = AgentHandoff.ensure(coordinator, id)
    before = calls(runtime)
    :sys.suspend(coordinator)

    assert :ok =
             AgentHandoff.handle_transition(
               [:oban_claude, :agent, :transition],
               %{},
               %{agent_id: id, from: :running, to: :paused},
               coordinator
             )

    assert calls(runtime) == before
    :sys.resume(coordinator)
  end

  defp dependencies(runtime) do
    %{
      routine_all: fn -> Agent.get(runtime, &Map.values(&1.routines)) end,
      routine_get: fn id -> Agent.get(runtime, &get_in(&1, [:routines, id])) end,
      routine_role: fn id ->
        case Agent.get(runtime, &get_in(&1, [:routines, id])) do
          nil -> nil
          routine -> Map.get(routine, :role, :assistant)
        end
      end,
      authorization_put: fn routine, revision ->
        snapshot = %{
          id: routine.id,
          execution_revision: revision,
          role: Map.get(routine, :role, :assistant),
          repo: Map.get(routine, :repo),
          workspace: Map.get(routine, :workspace, "/tmp/#{routine.id}"),
          working_dir: Map.get(routine, :working_dir, "/tmp/#{routine.id}")
        }

        Agent.update(
          runtime,
          &put_in(&1, [:authorization_snapshots, {routine.id, revision}], snapshot)
        )

        :ok
      end,
      authorization_get: fn id, revision ->
        Agent.get(runtime, &get_in(&1, [:authorization_snapshots, {id, revision}]))
      end,
      execution_revision: fn routine -> routine.revision end,
      delivery_revision: fn routine -> Map.get(routine, :delivery_revision, routine.revision) end,
      seed_map: fn routine -> Map.get(routine, :seed_map, %{}) end,
      agent_config: fn routine, session_arcs ->
        [config_revision: routine.revision, session_arcs: session_arcs]
      end,
      live_provider: fn id -> fake_live_provider(runtime, id) end,
      info: fn id, provider -> fake_info(runtime, id, provider) end,
      status: fn id, provider -> fake_status(runtime, id, provider) end,
      quiesce: fn id, provider, reason -> fake_quiesce(runtime, id, provider, reason) end,
      stop_agent: fn id, provider -> fake_stop(runtime, id, provider) end,
      await: fn id, provider, target, _timeout -> fake_await(runtime, id, provider, target) end,
      start_agent: fn id, provider, config -> fake_start(runtime, id, provider, config) end,
      emergency_pause: fn id, provider, context ->
        fake_pause(runtime, id, provider, context)
      end,
      resume_agent: fn id, provider -> fake_resume(runtime, id, provider) end,
      active_turn?: fn id -> Agent.get(runtime, &MapSet.member?(&1.active_turns, id)) end,
      active_turns: fn id ->
        Agent.get(runtime, fn state ->
          if MapSet.member?(state.active_turns, id) do
            state.active_turn_revisions
            |> Map.get(id)
            |> List.wrap()
            |> Enum.map(&%{meta: %{"config_revision" => &1}})
          else
            []
          end
        end)
      end,
      fence_stale_ticks: fn _id, _provider, _revision ->
        Agent.get(runtime, & &1.fence_result)
      end,
      pause_intent: fn id -> Agent.get(runtime, &get_in(&1, [:pause_intents, id])) end,
      put_pause_intent: fn id, context ->
        Agent.update(runtime, &put_in(&1, [:pause_intents, id], context))
        :ok
      end,
      clear_pause_intent: fn id ->
        Agent.update(
          runtime,
          &update_in(&1.pause_intents, fn intents -> Map.delete(intents, id) end)
        )

        :ok
      end,
      clear_absent_pause_intents: fn configured_ids ->
        configured = MapSet.new(configured_ids)

        Agent.update(runtime, fn state ->
          absent_ids =
            state.pause_intents |> Map.keys() |> Enum.reject(&MapSet.member?(configured, &1))

          %{
            state
            | pause_intents: Map.take(state.pause_intents, configured_ids),
              cleared_absent_pause_intents: absent_ids ++ state.cleared_absent_pause_intents
          }
        end)

        :ok
      end,
      defer_unstarted: fn _id -> :ok end,
      active_message_target_ids: fn -> Agent.get(runtime, & &1.active_message_targets) end,
      settle_removed_messages: fn id ->
        Agent.update(runtime, fn state ->
          %{
            state
            | active_message_targets: List.delete(state.active_message_targets, id),
              message_reconcile_order: state.message_reconcile_order ++ [{:settle_removed, id}],
              settled_removed: [id | state.settled_removed]
          }
        end)

        :ok
      end,
      reconcile_messages: fn ->
        Agent.update(runtime, fn state ->
          %{state | message_reconcile_order: state.message_reconcile_order ++ [:reconcile]}
        end)

        :ok
      end,
      queued?: fn id -> Agent.get(runtime, &MapSet.member?(&1.queued, id)) end,
      replay_next: fn id -> fake_replay(runtime, id) end,
      release_inbox: fn id -> record(runtime, {:release_inbox, id}) end
    }
  end

  defp fake_live_provider(runtime, id) do
    Agent.get(runtime, fn state ->
      case get_in(state, [:live, id]) do
        nil -> :offline
        live -> {:ok, live.provider}
      end
    end)
  end

  defp fake_info(runtime, id, provider) do
    record(runtime, {:info, id, provider})

    Agent.get(runtime, fn state ->
      case get_in(state, [:live, id]) do
        %{provider: ^provider} = live ->
          {:ok,
           %{
             state: state_of(live.state),
             config_revision: live.revision,
             deferred_pause: live.deferred_pause,
             pause_context: live.pause_context,
             session_arcs: live.session_arcs
           }}

        _missing ->
          {:error, :agent_not_running}
      end
    end)
  end

  defp fake_status(runtime, id, provider) do
    record(runtime, {:status, id, provider})

    Agent.get(runtime, fn state ->
      case get_in(state, [:live, id]) do
        %{provider: ^provider, state: provider_state} -> {:ok, provider_state}
        _missing -> {:ok, :offline}
      end
    end)
  end

  defp fake_quiesce(runtime, id, provider, reason) do
    record(runtime, {:quiesce, id, provider, reason})

    Agent.get_and_update(runtime, fn state ->
      case get_in(state, [:live, id]) do
        nil ->
          {{:error, :agent_not_running}, state}

        %{provider: ^provider, state: :paused, quiesce_draining?: true} ->
          {:draining, state}

        %{provider: ^provider, state: :paused} ->
          {:already_paused, state}

        %{provider: ^provider} = live ->
          fake_quiesce_live(state, id, live, reason)
      end
    end)
  end

  defp fake_quiesce_live(state, id, %{state: :idle} = live, _reason) do
    pause_context = %{cause: :quiesce, reason: :config_change}

    {:paused, put_in(state, [:live, id], %{live | state: :paused, pause_context: pause_context})}
  end

  defp fake_quiesce_live(state, id, live, reason) do
    latch = live.deferred_pause || %{cause: :quiesce, reason: reason}
    {:armed, put_in(state, [:live, id], %{live | deferred_pause: latch})}
  end

  defp fake_stop(runtime, id, provider) do
    record(runtime, {:stop, id, provider})
    Agent.update(runtime, &update_in(&1.live, fn live -> Map.delete(live, id) end))
    :ok
  end

  defp fake_await(runtime, id, provider, target) do
    record(runtime, {:await, id, provider, target})

    Agent.get(runtime, fn state ->
      actual =
        case get_in(state, [:live, id]) do
          nil -> :offline
          live -> state_of(live.state)
        end

      if actual == target, do: {:ok, actual}, else: {:error, :timeout}
    end)
  end

  defp fake_start(runtime, id, provider, config) do
    revision = Keyword.fetch!(config, :config_revision)
    session_arcs = Keyword.fetch!(config, :session_arcs)
    record(runtime, {:start, id, provider, revision, session_arcs})
    put_live(runtime, id, provider, :idle, revision, session_arcs: session_arcs)
    {:ok, self()}
  end

  defp fake_pause(runtime, id, provider),
    do: fake_pause(runtime, id, provider, %{cause: :emergency_pause, reason: :emergency_pause})

  defp fake_pause(runtime, id, provider, context) do
    record(runtime, {:emergency_pause, id, provider, context})

    result =
      Agent.get_and_update(runtime, fn state ->
        case state.pause_results do
          [result | rest] -> {result, %{state | pause_results: rest}}
          [] -> {:ok, state}
        end
      end)

    if result == :ok do
      Agent.update(runtime, fn runtime_state ->
        live = get_in(runtime_state, [:live, id])
        put_in(runtime_state, [:live, id], %{live | state: :paused, pause_context: context})
      end)
    end

    result
  end

  defp fake_resume(runtime, id, provider) do
    record(runtime, {:resume, id, provider})
    set_state(runtime, id, :idle)
    :resumed
  end

  defp fake_replay(runtime, id) do
    record(runtime, {:replay, id})

    Agent.get_and_update(runtime, fn state ->
      cond do
        state.replay_result != :ok ->
          {state.replay_result, state}

        MapSet.member?(state.queued, id) ->
          {{:accepted, "fake-message"}, update_in(state.queued, &MapSet.delete(&1, id))}

        true ->
          {:empty, state}
      end
    end)
  end

  defp put_routine(runtime, id, provider, revision, seed_map \\ %{}) do
    routine = %{id: id, provider: provider, revision: revision, seed_map: seed_map}
    Agent.update(runtime, &put_in(&1, [:routines, id], routine))
  end

  defp put_role(runtime, id, role) do
    Agent.update(runtime, &put_in(&1, [:routines, id, :role], role))
  end

  defp drop_routine(runtime, id) do
    Agent.update(runtime, &update_in(&1.routines, fn routines -> Map.delete(routines, id) end))
  end

  defp put_pause_intent(runtime, id, context) do
    Agent.update(runtime, &put_in(&1, [:pause_intents, id], context))
  end

  defp set_pause_results(runtime, results) do
    Agent.update(runtime, &%{&1 | pause_results: results})
  end

  defp put_live(runtime, id, provider, state, revision, opts \\ []) do
    live = %{
      provider: provider,
      state: state,
      revision: revision,
      deferred_pause: Keyword.get(opts, :deferred_pause),
      pause_context: Keyword.get(opts, :pause_context, Keyword.get(opts, :deferred_pause)),
      session_arcs: Keyword.get(opts, :session_arcs, %{}),
      quiesce_draining?: Keyword.get(opts, :quiesce_draining?, false)
    }

    Agent.update(runtime, &put_in(&1, [:live, id], live))
  end

  defp live(runtime, id), do: Agent.get(runtime, &get_in(&1, [:live, id]))

  defp set_state(runtime, id, state) do
    Agent.update(runtime, fn runtime_state ->
      live = get_in(runtime_state, [:live, id])

      pause_context =
        if state == :paused, do: live.deferred_pause || live.pause_context, else: nil

      put_in(runtime_state, [:live, id], %{live | state: state, pause_context: pause_context})
    end)
  end

  defp set_quiesce_draining(runtime, id, value) when is_boolean(value) do
    Agent.update(runtime, &put_in(&1, [:live, id, :quiesce_draining?], value))
  end

  defp drop_live(runtime, id) do
    Agent.update(runtime, &update_in(&1.live, fn live -> Map.delete(live, id) end))
  end

  defp set_queued(runtime, id) do
    Agent.update(runtime, &update_in(&1.queued, fn queued -> MapSet.put(queued, id) end))
  end

  defp set_active_turn(runtime, id, true) do
    Agent.update(runtime, &update_in(&1.active_turns, fn ids -> MapSet.put(ids, id) end))
  end

  defp set_active_turn(runtime, id, false) do
    Agent.update(runtime, &update_in(&1.active_turns, fn ids -> MapSet.delete(ids, id) end))
  end

  defp set_active_turn_revision(runtime, id, revision) do
    Agent.update(runtime, &put_in(&1, [:active_turn_revisions, id], revision))
  end

  defp set_active_turn_revisions(runtime, id, revisions) do
    Agent.update(runtime, &put_in(&1, [:active_turn_revisions, id], revisions))
  end

  defp set_fence_result(runtime, result) do
    Agent.update(runtime, &%{&1 | fence_result: result})
  end

  defp record(runtime, call) do
    Agent.update(runtime, &update_in(&1.calls, fn calls -> [call | calls] end))
  end

  defp calls(runtime), do: Agent.get(runtime, &Enum.reverse(&1.calls))

  defp state_of({state, _payload}), do: state
  defp state_of(state), do: state

  defp replaying_or_ready?(:ready), do: true
  defp replaying_or_ready?({:pending, %{phase: :replaying}}), do: true
  defp replaying_or_ready?(_status), do: false

  defp assert_eventually(fun, attempts \\ 100)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      assert true
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end

  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")
end
