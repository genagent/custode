defmodule Custode.Operator.SessionRehydrationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Agents, ConversationArcs, OperatorMessages, Repo, Routine}
  alias Custode.Operator.Actions

  setup do
    put_env!(:conversation_host_id, uid("rehydration-host"))
    path = Path.join(System.tmp_dir!(), uid("rehydration-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  for provider <- [:claude, :codex] do
    @provider provider

    test "#{@provider}: hot delivery after 32 fresh sweeps agrees with cold delivery" do
      provider = @provider
      routine = fixture!(provider)
      operator = establish_operator!(routine)
      last = evict_operator!(routine, operator)

      assert {:ok, hot, :created} = Actions.message_with_receipt(routine.id, "hot follow-up")
      hot_turn = latest_turn(provider, routine.id, last.id)
      assert_continuation(hot_turn, operator, hot.message_id, provider)

      assert Map.take(hot_turn.args, base_keys(provider)) ==
               Map.take(operator.turn.args, base_keys(provider))

      finish!(provider, hot_turn, plain_result(provider, operator.handle))
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)

      eventually(fn ->
        assert %{status: "completed"} = OperatorMessages.get(hot.message_id)
      end)

      assert :ok = Agents.stop_agent(routine.id, provider)
      assert ConversationArcs.seed_map(routine) == %{operator.arc => operator.handle}
      assert {:ok, cold, :created} = Actions.message_with_receipt(routine.id, "cold follow-up")
      cold_turn = latest_turn(provider, routine.id, hot_turn.id)
      assert_continuation(cold_turn, operator, cold.message_id, provider)

      assert Map.take(cold_turn.args, base_keys(provider)) ==
               Map.take(hot_turn.args, base_keys(provider))

      finish!(provider, cold_turn, plain_result(provider, operator.handle))
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)
      assert_durable_handle(routine.id, operator)
    end

    test "#{@provider}: an exact durable handle cannot overwrite a different live handle" do
      provider = @provider
      routine = fixture!(provider)
      operator = establish_operator!(routine)
      live_handle = restart_with_conflict!(routine, operator)

      assert {:ok, prompt, opts} = ConversationArcs.operator_delivery(routine, "continue")
      assert opts[:resume_session_id] == operator.handle
      assert {:error, {:session_conflict, arc}} = Agents.submit_prompt(routine.id, prompt, opts)
      assert arc == operator.arc
      assert latest_turn(provider, routine.id, 0).id == operator.turn.id
      assert {:ok, info} = Agents.info(routine.id, provider)
      assert info.session_arcs[operator.arc] == live_handle
      assert_durable_handle(routine.id, operator)
    end

    test "#{@provider}: queued refusal retains input and never retries fresh" do
      provider = @provider
      routine = fixture!(provider)
      operator = establish_operator!(routine)
      live_handle = restart_with_conflict!(routine, operator)
      sweep = start_sweep!(routine, operator.turn.id)

      assert {:ok, message, :created} =
               Actions.message_with_receipt(routine.id, "keep this durable input")

      assert message.delivery == "queued"
      finish!(provider, sweep, plain_result(provider, uid("sweep-handle")))
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)

      # Retry the durable replay explicitly as well as the coordinator's
      # transition replay. Both must refuse the conflict without fresh retry.
      eventually(fn ->
        assert %{delivery: "queued", prompt: "keep this durable input"} =
                 OperatorMessages.get(message.message_id)

        assert {:error, {message_id, {:session_conflict, arc}}} =
                 Actions.replay_next(routine.id)

        assert message_id == message.message_id
        assert arc == operator.arc
      end)

      assert latest_turn(provider, routine.id, 0).id == sweep.id
      assert {:ok, info} = Agents.info(routine.id, provider)
      assert info.session_arcs[operator.arc] == live_handle
      assert_durable_handle(routine.id, operator)

      # A concurrent coordinator replay may briefly reclaim the input after
      # the explicit refusal above. Wait for that attempt's refusal to settle.
      eventually(fn ->
        assert %{delivery: "queued", status: "queued"} =
                 OperatorMessages.get(message.message_id)

        assert latest_turn(provider, routine.id, 0).id == sweep.id
      end)
    end

    test "#{@provider}: a queued answer after eviction stays on the questioning sweep" do
      provider = @provider
      routine = fixture!(provider)
      operator = establish_operator!(routine)
      last = evict_operator!(routine, operator)
      sweep = start_sweep!(routine, last.id)

      assert {:ok, message, :created} = Actions.message_with_receipt(routine.id, "staging")
      assert message.delivery == "queued"
      handle = uid("question-handle")
      finish!(provider, sweep, question_result(provider, handle))
      answer = latest_turn(provider, routine.id, sweep.id)
      assert answer.meta["arc_id"] == sweep.meta["arc_id"]
      assert answer.meta["arc_id"] != operator.arc
      assert answer.args[resume_key(provider)] == handle
      assert answer.meta["session_id"] == handle
      assert answer.meta["origin"] == "operator"
      assert answer.meta["correlation_id"] == message.message_id

      assert Map.take(answer.args, base_keys(provider)) ==
               Map.take(sweep.args, base_keys(provider))

      finish!(provider, answer, plain_result(provider, handle))
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)
      assert_durable_handle(routine.id, operator)
    end

    test "#{@provider}: fresh without a handle and explicit fallback omit rehydration" do
      provider = @provider
      routine = fixture!(provider)
      assert {:ok, _, opts} = ConversationArcs.operator_delivery(routine, "first")
      assert opts[:session] == :resume
      refute Keyword.has_key?(opts, :resume_session_id)

      operator = establish_operator!(routine)
      assert {:ok, _, opts} = ConversationArcs.operator_delivery(routine, "continue")
      assert opts[:resume_session_id] == operator.handle

      rejected = reject_resume!(routine, operator)
      assert {:ok, prompt, opts} = ConversationArcs.operator_delivery(routine, "recover")
      assert opts[:session] == :fresh_fallback
      refute Keyword.has_key?(opts, :resume_session_id)
      assert prompt =~ "Custode continuity recovery"
      assert :processing = Agents.submit_prompt(routine.id, prompt, opts)
      fallback = latest_turn(provider, routine.id, rejected.id)
      refute Map.has_key?(fallback.args, resume_key(provider))
      assert fallback.meta["arc_id"] == operator.arc
      finish!(provider, fallback, plain_result(provider, uid("replacement-handle")))
      assert {:ok, :idle} = Agents.await(routine.id, provider, :idle, 1_000)
    end

    for handle <- ["", " \t "] do
      @blank_handle handle

      test "#{@provider}: a persisted blank handle #{inspect(@blank_handle)} is not rehydrated" do
        routine = fixture!(@provider)
        assert {:ok, prepared} = ConversationArcs.prepare(routine, :operator)

        # Set only this fixture's row, bypassing cast's empty-value cleanup to
        # represent a retained blank handle from an older writer.
        prepared.arc
        |> Ecto.Changeset.change(provider_session_id: @blank_handle)
        |> Repo.update!()

        assert {:ok, _, opts} = ConversationArcs.operator_delivery(routine, "continue")
        assert opts[:session] == :resume
        refute Keyword.has_key?(opts, :resume_session_id)
      end
    end

    for change <- [:host, :workspace, :provider, :configuration, :explicit] do
      @change change

      test "#{@provider}: #{@change} rotation omits the old durable handle" do
        routine = fixture!(@provider)
        operator = establish_operator!(routine)
        changed = rotate_fixture!(routine, @change)
        assert {:ok, _, opts} = ConversationArcs.operator_delivery(changed, "new generation")
        assert opts[:arc_id] != operator.arc
        refute Keyword.has_key?(opts, :resume_session_id)
        assert ConversationArcs.seed_map(changed) == %{}
        assert [old, current] = ConversationArcs.history(routine.id, "operator")
        assert old.state == "rotated"
        assert old.provider_session_id == operator.handle
        assert current.provider_session_id == nil
        assert current.last_decision == "fresh"
        assert current.last_reason == rotation_reason(@change)
      end
    end
  end

  defp fixture!(provider) do
    routine = routine_fixture!(tmp_workspace!(), %{provider: provider, model: model(provider)})
    on_exit(fn -> Agents.stop_agent(routine.id, provider) end)
    routine
  end

  defp establish_operator!(routine) do
    assert {:ok, message, :created} =
             Actions.message_with_receipt(routine.id, "remember the release checklist")

    turn = latest_turn(routine.provider, routine.id, 0)
    refute Map.has_key?(turn.args, resume_key(routine.provider))
    assert turn.meta["correlation_id"] == message.message_id
    # Surrounding whitespace belongs to a nonblank opaque handle. Admission
    # must pass the exact stored bytes rather than normalize the handle.
    operator = %{
      arc: turn.meta["arc_id"],
      handle: " " <> uid("operator-handle") <> " ",
      turn: turn
    }

    finish!(routine.provider, turn, plain_result(routine.provider, operator.handle))
    assert {:ok, :idle} = Agents.await(routine.id, routine.provider, :idle, 1_000)
    assert_durable_handle(routine.id, operator)
    operator
  end

  defp evict_operator!(routine, operator) do
    last =
      Enum.reduce(1..32, operator.turn, fn _, previous ->
        sweep = start_sweep!(routine, previous.id)
        finish!(routine.provider, sweep, plain_result(routine.provider, uid("sweep-handle")))
        assert {:ok, :idle} = Agents.await(routine.id, routine.provider, :idle, 1_000)
        sweep
      end)

    assert {:ok, info} = Agents.info(routine.id, routine.provider)
    assert map_size(info.session_arcs) == 32
    refute Map.has_key?(info.session_arcs, operator.arc)
    assert_durable_handle(routine.id, operator)
    last
  end

  defp start_sweep!(routine, after_id) do
    assert {:ok, args, prepared} = ConversationArcs.tick_args(routine, :scheduled)
    assert args["session"] == "fresh"
    assert :ok = Agents.tick_worker(routine).perform(%Oban.Job{args: args})
    turn = latest_turn(routine.provider, routine.id, after_id)
    assert turn.meta["arc_id"] == prepared.arc_id
    assert turn.meta["origin"] == "tick"
    refute Map.has_key?(turn.args, resume_key(routine.provider))
    turn
  end

  defp restart_with_conflict!(routine, operator) do
    assert :ok = Agents.stop_agent(routine.id, routine.provider)
    handle = uid("different-live-handle")
    config = Routine.agent_config(routine, %{operator.arc => handle})
    assert {:ok, _pid} = Agents.start_agent(routine.id, routine.provider, config)
    handle
  end

  defp rotate_fixture!(routine, :host) do
    put_env!(:conversation_host_id, uid("replacement-host"))
    routine
  end

  defp rotate_fixture!(routine, :workspace),
    do: %{routine | working_dir: tmp_workspace!()}

  defp rotate_fixture!(routine, :provider) do
    provider = if routine.provider == :claude, do: :codex, else: :claude
    %{routine | provider: provider, model: model(provider)}
  end

  defp rotate_fixture!(routine, :configuration), do: %{routine | model: "replacement-model"}

  defp rotate_fixture!(routine, :explicit) do
    assert {:ok, _arc} = ConversationArcs.rotate(routine.id, "operator")
    routine
  end

  defp reject_resume!(routine, operator) do
    assert {:ok, :delivered} = Actions.message(routine.id, "resume before rejection")
    turn = latest_turn(routine.provider, routine.id, operator.turn.id)
    assert turn.args[resume_key(routine.provider)] == operator.handle

    # The existing explicit rejection verdict drives real wrapper telemetry.
    # Native missing-transcript classification remains a separate issue.
    assert {:cancel, :invalid_session} =
             job_module(routine.provider).handle_error(
               {:cancel, :invalid_session},
               %{reason: :invalid_session},
               %Oban.Job{id: turn.id, meta: turn.meta, attempt: 1, max_attempts: 1}
             )

    Oban.Job
    |> Repo.get!(turn.id)
    |> Ecto.Changeset.change(state: "cancelled", cancelled_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, :idle} = Agents.await(routine.id, routine.provider, :idle, 1_000)

    eventually(fn ->
      assert %{provider_session_id: nil, decision: "resume"} =
               ConversationArcs.read_model(routine.id).current
    end)

    turn
  end

  defp assert_continuation(turn, operator, correlation_id, provider) do
    assert turn.meta["arc_id"] == operator.arc
    assert turn.meta["session_id"] == operator.handle
    assert turn.args[resume_key(provider)] == operator.handle
    assert turn.meta["origin"] == "operator"
    assert turn.meta["correlation_id"] == correlation_id
    assert turn.args["model"] == model(provider)

    case provider do
      :claude ->
        refute turn.args["permission_mode"] == "bypass_permissions"

      :codex ->
        assert turn.args["sandbox"] == "read_only"
        assert turn.args["approval_policy"] == "never"
    end
  end

  defp assert_durable_handle(id, operator) do
    eventually(fn ->
      assert %{arc_id: arc, provider_session_id: handle} = ConversationArcs.read_model(id).current
      assert arc == operator.arc
      assert handle == operator.handle
    end)
  end

  defp latest_turn(provider, agent_id, after_id) do
    eventually(fn ->
      job =
        provider
        |> job_module()
        |> inspect()
        |> jobs_for()
        |> Enum.filter(&(&1.meta["agent_id"] == agent_id and &1.id > after_id))
        |> List.last()

      assert %{id: id} = job
      assert is_integer(id)
      job
    end)
  end

  defp finish!(provider, job, result) do
    :ok =
      job_module(provider).handle_result(
        result,
        %Oban.Job{id: job.id, meta: job.meta, attempt: 1, max_attempts: 1}
      )

    # Mirror Oban's terminal boundary for this test's own controlled job.
    Oban.Job
    |> Repo.get!(job.id)
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    :ok
  end

  defp question_result(:claude, handle),
    do:
      ObanClaude.Testing.structured_result(
        %{"directive" => "ask_user", "question" => "which environment?"},
        session_id: handle
      )

  defp question_result(:codex, handle),
    do:
      ObanCodex.Testing.structured_result(
        %{"directive" => "ask_user", "question" => "which environment?"},
        session_id: handle
      )

  defp plain_result(:claude, handle),
    do: ObanClaude.Testing.result(result: "done", session_id: handle)

  defp plain_result(:codex, handle), do: ObanCodex.Testing.result("done", session_id: handle)
  defp job_module(:claude), do: ObanClaude.Agent.Job
  defp job_module(:codex), do: ObanCodex.Agent.Job
  defp resume_key(:claude), do: "resume"
  defp resume_key(:codex), do: "session_id"
  defp model(:claude), do: "haiku"
  defp model(:codex), do: "gpt-5.6-sol"
  defp base_keys(:claude), do: ~w(model permission_mode working_dir max_turns)
  defp base_keys(:codex), do: ~w(model sandbox approval_policy working_dir)
  defp rotation_reason(:host), do: "host_changed"
  defp rotation_reason(:workspace), do: "workspace_changed"
  defp rotation_reason(:provider), do: "provider_changed"
  defp rotation_reason(:configuration), do: "configuration_changed"
  defp rotation_reason(:explicit), do: "no_session"
end
