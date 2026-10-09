defmodule Custode.Operator.AnswerReplayTest do
  # #853: an operator message queued behind a sweep that then asks a question
  # is that question's answer. Replay must deliver it on the asking arc and its
  # native session, as immediate delivery does, and not on the operator arc.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Agents, ConversationArcs, OperatorMessages, Repo}
  alias Custode.Operator.Actions

  setup do
    put_env!(:conversation_host_id, "test-host")
    path = Path.join(System.tmp_dir!(), uid("answer-replay") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  for provider <- [:claude, :codex],
      kind <- [:scheduled, :inbox],
      earlier <- [:operator_arc, :no_operator_arc] do
    @provider provider
    @kind kind
    @earlier earlier

    test "#{@provider}: a queued message answers the #{@kind} arc's question (#{@earlier})" do
      provider = @provider

      routine =
        routine_fixture!(tmp_workspace!(), %{provider: provider, model: model(provider)})

      id = routine.id
      on_exit(fn -> Agents.stop_agent(id, provider) end)

      operator = if @earlier == :operator_arc, do: establish_operator_arc!(provider, id)
      after_id = if operator, do: operator.turn.id, else: 0

      sweep_arc = start_sweep!(@kind, routine)
      sweep = latest_turn(provider, id, after_id)
      assert sweep.meta["arc_id"] == sweep_arc
      assert sweep.meta["origin"] == "tick"
      refute Map.has_key?(sweep.args, resume_key(provider))

      # Admission defers the message while the fresh sweep runs. Its transition
      # to waiting_for_user must drive real durable replay, without a direct call.
      assert {:ok, answer_message, :created} =
               Actions.message_with_receipt(id, "staging, then report back")

      assert answer_message.delivery == "queued"
      assert OperatorMessages.get(answer_message.message_id).delivery == "queued"

      sweep_handle = native_handle("sweep")
      finish!(provider, sweep, question_result(provider, "which environment?", sweep_handle))

      # The coordinator replays the oldest row through Actions.replay_next/1.
      answer = latest_turn(provider, id, sweep.id)
      assert answer.args["prompt"] =~ "staging, then report back"
      assert answer.meta["arc_id"] == sweep_arc
      assert answer.meta["session_id"] == sweep_handle
      assert answer.args[resume_key(provider)] == sweep_handle
      assert answer.meta["origin"] == "operator"
      assert answer.meta["correlation_id"] == answer_message.message_id

      if operator do
        refute answer.meta["arc_id"] == operator.arc
        refute answer.args[resume_key(provider)] == operator.handle
      end

      # The answer runs under the captured base settings, not approved authority.
      assert answer.args["model"] == model(provider)

      assert Map.take(answer.args, base_keys(provider)) ==
               Map.take(sweep.args, base_keys(provider))

      case provider do
        :claude ->
          refute answer.args["permission_mode"] == "bypass_permissions"

        :codex ->
          assert answer.args["sandbox"] == "read_only"
          assert answer.args["approval_policy"] == "never"
      end

      eventually(fn ->
        assert %{delivery: "delivered", provider: delivered_by} =
                 OperatorMessages.get(answer_message.message_id)

        assert delivered_by == to_string(provider)
      end)

      finish!(provider, answer, plain_result(provider, sweep_handle))
      assert {:ok, :idle} = Agents.await(id, provider, :idle, 1_000)

      eventually(fn ->
        assert %{status: "completed"} = OperatorMessages.get(answer_message.message_id)

        if operator do
          assert %{arc_id: arc, provider_session_id: handle} =
                   ConversationArcs.read_model(id).current

          assert arc == operator.arc
          assert handle == operator.handle
        end
      end)
    end
  end

  defp establish_operator_arc!(provider, id) do
    assert {:ok, :started} = Actions.message(id, "remember the release checklist")
    turn = latest_turn(provider, id, 0)
    arc = turn.meta["arc_id"]
    assert arc =~ "operator:"

    handle = native_handle("operator")
    finish!(provider, turn, plain_result(provider, handle))
    assert {:ok, :idle} = Agents.await(id, provider, :idle, 1_000)

    eventually(fn ->
      assert %{arc_id: ^arc, provider_session_id: ^handle} =
               ConversationArcs.read_model(id).current
    end)

    %{arc: arc, handle: handle, turn: turn}
  end

  defp start_sweep!(:scheduled, routine) do
    assert :ok = Custode.RoutineTick.perform(%Oban.Job{args: %{"routine_id" => routine.id}})
    run_tick!(routine, "scheduled:")
  end

  defp start_sweep!(:inbox, routine) do
    assert {:ok, args, prepared} =
             ConversationArcs.tick_args(routine, :inbox, arc_id: "inbox:" <> uid("wake"))

    assert prepared.arc.kind == "inbox"
    assert {:ok, _job} = Oban.insert(Agents.tick_worker(routine).new(args, queue: :ticks))
    run_tick!(routine, "inbox:")
  end

  defp run_tick!(routine, prefix) do
    tick = latest_tick(routine)
    assert tick.args["arc_id"] =~ prefix
    assert tick.args["session"] == "fresh"
    assert :ok = Agents.tick_worker(routine).perform(%Oban.Job{args: tick.args})
    tick.args["arc_id"]
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

  defp latest_tick(routine) do
    eventually(fn ->
      job =
        routine
        |> Agents.tick_worker()
        |> inspect()
        |> jobs_for()
        |> Enum.filter(&(&1.args["agent_id"] == routine.id))
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

    # handle_result/2 simulates the worker callback. Real Oban marks the row
    # terminal when that callback returns; mirror that physical boundary here.
    Oban.Job
    |> Repo.get!(job.id)
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    :ok
  end

  defp question_result(:claude, question, handle) do
    ObanClaude.Testing.structured_result(
      %{"directive" => "ask_user", "question" => question},
      session_id: handle
    )
  end

  defp question_result(:codex, question, handle) do
    ObanCodex.Testing.structured_result(
      %{"directive" => "ask_user", "question" => question},
      session_id: handle
    )
  end

  defp plain_result(:claude, handle),
    do: ObanClaude.Testing.result(result: "done", session_id: handle)

  defp plain_result(:codex, handle), do: ObanCodex.Testing.result("done", session_id: handle)

  defp native_handle(label), do: uid("native-#{label}")

  defp job_module(:claude), do: ObanClaude.Agent.Job
  defp job_module(:codex), do: ObanCodex.Agent.Job

  # Claude resumes with `resume`; Codex threads the same handle as `session_id`.
  defp resume_key(:claude), do: "resume"
  defp resume_key(:codex), do: "session_id"

  defp model(:claude), do: "haiku"
  defp model(:codex), do: "gpt-5.6-sol"

  defp base_keys(:claude), do: ~w(model permission_mode working_dir max_turns)
  defp base_keys(:codex), do: ~w(model sandbox approval_policy working_dir)
end
