defmodule Custode.EarlySessionObservationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.ConversationArcs

  setup do
    put_env!(:conversation_host_id, "early-session-host")
    :ok
  end

  test "both providers persist a session before completion without reporting success" do
    for provider <- [:claude, :codex] do
      {routine, prepared, meta} = execution(provider)
      emit(provider, :execution_started, meta)
      emit(provider, :session_observed, observation(provider, meta, "early-native"))

      assert %{provider_session_id: "early-native", outcome: nil} =
               ConversationArcs.read_model(routine.id).current

      assert ConversationArcs.seed_map(routine) == %{prepared.arc_id => "early-native"}
      assert {:ok, %{decision: :resume}} = ConversationArcs.prepare(routine, :operator)
    end
  end

  test "duplicate and conflicting observations leave one durable accepted identity" do
    {routine, prepared, meta} = execution(:claude)
    emit(:claude, :execution_started, meta)
    emit(:claude, :execution_started, meta)
    emit(:claude, :session_observed, observation(:claude, meta, "first"))
    emit(:claude, :session_observed, observation(:claude, meta, "first"))
    emit(:claude, :session_observed, observation(:claude, meta, "conflict"))

    assert ConversationArcs.read_model(routine.id).current.provider_session_id == "first"
    assert Enum.count(events(prepared), &(&1.kind == "execution_started")) == 1
    assert Enum.count(events(prepared), &(&1.kind == "session_observed")) == 1
  end

  test "an observation needs a valid identity, provider source and current execution" do
    {routine, _prepared, meta} = execution(:claude)
    observed = observation(:claude, meta, "native")
    emit(:claude, :session_observed, observed)
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
    emit(:claude, :execution_started, meta)

    for invalid <- [
          %{observed | session_id: nil},
          %{observed | session_id: " \n"},
          %{observed | source: :thread_started},
          %{observed | agent_generation: "another-generation"},
          %{observed | agent_turn_id: "another-turn"},
          %{observed | job_id: meta.job_id + 1},
          %{observed | job_attempt: 2},
          %{observed | job_snoozed: 1},
          Map.delete(observed, :job_id)
        ] do
      emit(:claude, :session_observed, invalid)
      assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
    end

    emit(:codex, :session_observed, observation(:codex, meta, "wrong-provider"))
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
  end

  test "malformed new completions cannot fall back to the legacy completion contract" do
    {routine, _prepared, meta} = execution(:claude)
    completed = completion(meta, :completed, "unaccepted")

    for key <- [:job_id, :job_attempt, :job_snoozed] do
      emit(:claude, :turn_completed, Map.delete(completed, key))
      assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
      assert ConversationArcs.read_model(routine.id).current.outcome == nil
    end

    emit(:claude, :turn_completed, Map.drop(completed, [:job_id, :job_attempt, :job_snoozed]))
    assert ConversationArcs.read_model(routine.id).current.outcome == nil

    emit(:claude, :execution_started, meta)
    emit(:claude, :session_observed, observation(:claude, meta, "accepted"))
    malformed = Map.put(completion(meta, :enqueue_failed, nil), :execution_state, :not_started)
    emit(:claude, :turn_completed, malformed)

    assert %{provider_session_id: "accepted", outcome: nil} =
             ConversationArcs.read_model(routine.id).current

    # The malformed diagnostic must not retire the actual execution.
    emit(:claude, :turn_completed, completion(meta, :completed, "accepted"))
    assert ConversationArcs.read_model(routine.id).current.outcome == "completed"
  end

  test "a newer retry rejects old observations and terminal callbacks" do
    {routine, _prepared, first} = execution(:codex)
    second = %{first | job_attempt: 2, job_snoozed: 1}
    emit(:codex, :execution_started, first)
    emit(:codex, :execution_started, second)
    emit(:codex, :execution_started, first)
    emit(:codex, :session_observed, observation(:codex, first, "stale"))
    emit(:codex, :turn_completed, completion(first, :session_rejected, "stale"))
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil

    emit(:codex, :session_observed, observation(:codex, second, "current"))
    emit(:codex, :turn_completed, completion(first, :session_rejected, "stale"))
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == "current"
    assert ConversationArcs.read_model(routine.id).current.outcome == nil
  end

  test "new generation and turn reject a prior execution on the same arc" do
    {routine, _prepared, first} = execution(:claude)

    second = %{
      first
      | agent_generation: "replacement-generation",
        agent_turn_id: "next-turn",
        job_id: first.job_id + 1
    }

    emit(:claude, :execution_started, first)
    emit(:claude, :execution_started, second)
    emit(:claude, :session_observed, observation(:claude, first, "old"))
    emit(:claude, :turn_completed, completion(first, :completed, "old"))
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
    emit(:claude, :session_observed, observation(:claude, second, "new"))
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == "new"
  end

  test "rotation rejects both a late observation and a late completion" do
    {routine, prepared, meta} = execution(:claude)
    emit(:claude, :execution_started, meta)
    assert {:ok, _closed} = ConversationArcs.rotate(routine.id, "operator")
    assert {:ok, fresh} = ConversationArcs.prepare(routine, :operator)
    emit(:claude, :session_observed, observation(:claude, meta, "late"))
    emit(:claude, :turn_completed, completion(meta, :completed, "late"))

    assert fresh.arc_id != prepared.arc_id
    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil
    assert [old, _fresh] = ConversationArcs.history(routine.id, "operator")
    assert old.provider_session_id == nil
    refute Enum.any?(old.events, &(&1.kind in ["session_observed", "completion"]))
  end

  test "failure outcomes preserve the observed handle for the next compatible turn" do
    for outcome <- [:timeout, :cancelled, :rail_stopped, :failed] do
      {routine, _prepared, meta} = execution(:claude)
      emit(:claude, :execution_started, meta)
      emit(:claude, :session_observed, observation(:claude, meta, "resume-after-failure"))
      emit(:claude, :turn_completed, completion(meta, outcome, nil))

      assert %{provider_session_id: "resume-after-failure", outcome: recorded} =
               ConversationArcs.read_model(routine.id).current

      assert recorded == to_string(outcome)
      assert {:ok, %{decision: :resume}} = ConversationArcs.prepare(routine, :operator)
    end
  end

  test "completion retires observation authority and is idempotent" do
    {routine, prepared, meta} = execution(:codex)
    emit(:codex, :execution_started, meta)
    emit(:codex, :turn_completed, completion(meta, :failed, nil))
    emit(:codex, :session_observed, observation(:codex, meta, "too-late"))
    emit(:codex, :turn_completed, completion(meta, :completed, "too-late"))

    assert %{provider_session_id: nil, outcome: "failed"} =
             ConversationArcs.read_model(routine.id).current

    assert Enum.count(events(prepared), &(&1.kind == "completion")) == 1
    assert {:ok, %{decision: :fresh}} = ConversationArcs.prepare(routine, :operator)
  end

  test "explicit rejection clears an observed handle and selects durable-context recovery" do
    {routine, _prepared, meta} = execution(:codex)
    emit(:codex, :execution_started, meta)
    emit(:codex, :session_observed, observation(:codex, meta, "rejected-native"))
    emit(:codex, :turn_completed, completion(meta, :session_rejected, "rejected-native"))

    assert ConversationArcs.read_model(routine.id).current.provider_session_id == nil

    assert {:ok, %{decision: :fresh_fallback, reason: :resume_failed}} =
             ConversationArcs.prepare(routine, :operator)
  end

  test "a fresh replacement observed after rejection can resume before its first completion" do
    {routine, prepared, rejected} = execution(:claude)
    emit(:claude, :execution_started, rejected)
    emit(:claude, :session_observed, observation(:claude, rejected, "rejected"))
    emit(:claude, :turn_completed, completion(rejected, :session_rejected, "rejected"))
    assert {:ok, %{decision: :fresh_fallback}} = ConversationArcs.prepare(routine, :operator)

    replacement = %{
      rejected
      | agent_generation: "replacement-generation",
        agent_turn_id: "replacement-turn",
        job_id: rejected.job_id + 1
    }

    emit(:claude, :execution_started, replacement)
    emit(:claude, :session_observed, observation(:claude, replacement, "replacement-native"))
    assert ConversationArcs.seed_map(routine) == %{prepared.arc_id => "replacement-native"}

    assert {:ok, %{decision: :resume, reason: :session_available}} =
             ConversationArcs.prepare(routine, :operator)
  end

  test "fork rejection clears only the exact source handle and preserves the target" do
    for provider <- [:claude, :codex], replaced? <- [false, true] do
      {routine, target, target_meta} = execution(provider)
      emit(provider, :execution_started, target_meta)
      emit(provider, :session_observed, observation(provider, target_meta, "target-native"))
      emit(provider, :turn_completed, completion(target_meta, :completed, "target-native"))
      assert {:ok, source} = ConversationArcs.prepare(routine, :specialist, arc_id: "source")
      source_meta = %{target_meta | arc_id: source.arc_id, job_id: target_meta.job_id + 1}
      emit(provider, :execution_started, source_meta)
      emit(provider, :session_observed, observation(provider, source_meta, "source-native"))
      emit(provider, :turn_completed, completion(source_meta, :completed, "source-native"))

      if replaced? do
        newer = %{
          source_meta
          | job_id: source_meta.job_id + 1,
            agent_turn_id: "source-replacement"
        }

        emit(provider, :execution_started, newer)
        emit(provider, :session_observed, observation(provider, newer, "replacement-native"))
        emit(provider, :turn_completed, completion(newer, :completed, "replacement-native"))
      end

      fork_meta = %{target_meta | job_id: target_meta.job_id + 3, agent_turn_id: "fork"}
      emit(provider, :execution_started, fork_meta)

      rejected =
        fork_meta
        |> completion(:session_rejected, "target-native")
        |> Map.merge(%{
          fork_from_arc_id: source.arc_id,
          rejected_arc_id: source.arc_id,
          rejected_session_id: "source-native"
        })

      emit(provider, :turn_completed, rejected)
      assert ConversationArcs.seed_map(routine)[target.arc_id] == "target-native"
      assert {:ok, %{decision: :resume}} = ConversationArcs.prepare(routine, :operator)

      assert {:ok, prepared_source} =
               ConversationArcs.prepare(routine, :specialist, arc_id: "source")

      if replaced? do
        assert prepared_source.decision == :resume
        assert prepared_source.arc.provider_session_id == "replacement-native"
      else
        assert prepared_source.decision == :fresh_fallback
        assert prepared_source.arc.provider_session_id == nil
        assert Enum.count(events(source), &(&1.kind == "session_rejected")) == 1
      end
    end
  end

  test "a watchdog before execution records the timeout without erasing a previous handle" do
    {routine, _prepared, meta} = execution(:claude)
    emit(:claude, :execution_started, meta)
    emit(:claude, :session_observed, observation(:claude, meta, "retained"))
    emit(:claude, :turn_completed, completion(meta, :completed, "retained"))

    timed_out =
      meta
      |> completion(:timed_out, nil)
      |> Map.drop([:job_id, :job_attempt, :job_snoozed])
      |> Map.merge(%{agent_turn_id: "queued-timeout", execution_state: :not_started})

    emit(:claude, :turn_completed, timed_out)

    assert %{provider_session_id: "retained", outcome: "timed_out"} =
             ConversationArcs.read_model(routine.id).current

    assert {:ok, %{decision: :resume}} = ConversationArcs.prepare(routine, :operator)
  end

  test "specialist assignments can resume an early handle without any terminal result" do
    {routine, prepared, meta} = execution(:codex, :specialist)
    emit(:codex, :execution_started, meta)
    emit(:codex, :session_observed, observation(:codex, meta, "specialist-native"))

    assert {:ok, %{decision: :resume, arc_id: arc_id}} =
             ConversationArcs.prepare(routine, :specialist, arc_id: prepared.arc.logical_id)

    assert arc_id == prepared.arc_id
  end

  test "an accepted enqueue failure preserves the handle without replacing the execution tuple" do
    {routine, prepared, meta} = execution(:claude)
    emit(:claude, :execution_started, meta)
    emit(:claude, :session_observed, observation(:claude, meta, "retained"))
    emit(:claude, :turn_completed, completion(meta, :completed, "retained"))

    failed =
      meta
      |> completion(:enqueue_failed, nil)
      |> Map.drop([:job_id, :job_attempt, :job_snoozed])
      |> Map.merge(%{agent_turn_id: "not-enqueued", execution_state: :not_started})

    emit(:claude, :turn_completed, failed)

    assert %{provider_session_id: "retained", outcome: "enqueue_failed"} =
             ConversationArcs.read_model(routine.id).current

    assert Enum.count(events(prepared), &(&1.kind == "execution_started")) == 1
  end

  test "scheduled arcs stay fresh and close even when an early identity was observed" do
    {routine, prepared, meta} = execution(:claude, :scheduled)
    emit(:claude, :execution_started, meta)
    emit(:claude, :session_observed, observation(:claude, meta, "sweep-native"))
    assert ConversationArcs.seed_map(routine) == %{}
    emit(:claude, :turn_completed, completion(meta, :failed, nil))
    assert [closed] = ConversationArcs.history(routine.id, prepared.arc.logical_id)
    assert closed.state == "completed"
    assert closed.provider_session_id == "sweep-native"

    assert {:ok, %{decision: :fresh, arc_id: next_id}} =
             ConversationArcs.prepare(routine, :scheduled)

    assert next_id != prepared.arc_id
  end

  defp execution(provider, kind \\ :operator) do
    routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
    assert {:ok, prepared} = ConversationArcs.prepare(routine, kind)

    meta = %{
      agent_id: routine.id,
      agent_generation: uid("generation"),
      agent_turn_id: uid("turn"),
      arc_id: prepared.arc_id,
      job_id: System.unique_integer([:positive, :monotonic]),
      job_attempt: 1,
      job_snoozed: 0
    }

    {routine, prepared, meta}
  end

  defp observation(provider, meta, session_id) do
    source = if provider == :claude, do: :system_init, else: :thread_started
    Map.merge(meta, %{session_id: session_id, source: source})
  end

  defp completion(meta, outcome, session_id) do
    Map.merge(meta, %{
      session_id: session_id,
      continuation_decision: :fresh,
      continuation_reason: :requested,
      outcome: outcome,
      outcome_reason: nil,
      execution_state: :started
    })
  end

  defp emit(provider, event, meta) do
    namespace = if provider == :claude, do: :oban_claude, else: :oban_codex
    ConversationArcs.handle_event([namespace, :agent, event], %{}, meta, nil)
  end

  defp events(prepared) do
    [arc] = ConversationArcs.history(prepared.arc.routine_id, prepared.arc.logical_id)
    arc.events
  end
end
