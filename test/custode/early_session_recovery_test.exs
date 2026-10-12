defmodule Custode.EarlySessionRecoveryTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    AgentHandoff,
    Agents,
    ConversationArcs,
    ExecutionFacts,
    OperatorMessages,
    Repo,
    Routine
  }

  alias Custode.Operator.Actions

  setup do
    for {app, runner} <- [
          {:claude_wrapper, ClaudeWrapper.Runner.Forcola},
          {:codex_wrapper, CodexWrapper.Runner.Forcola}
        ] do
      previous = Application.get_env(app, :runner)
      Application.put_env(app, :runner, runner)

      on_exit(fn ->
        if previous,
          do: Application.put_env(app, :runner, previous),
          else: Application.delete_env(app, :runner)
      end)
    end

    put_env!(:conversation_host_id, "early-recovery-host")
    :ok
  end

  for provider <- [:claude, :codex],
      failure <- [:timeout, :worker_killed],
      ordering <- [:ordinary, :replay_first] do
    @provider provider
    @failure failure
    @ordering ordering
    @tag provider: provider

    test "#{provider} resumes its early handle after #{failure} with #{ordering} admission" do
      provider = @provider
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{provider: provider, cron: :manual})
      on_exit(fn -> Agents.stop_agent(routine.id, provider) end)
      binary = Path.join(workspace, "fake-provider")
      native_id = uid("native")
      write_cli!(binary, provider, native_id, :block)

      assert {:ok, initial, :created} = Actions.message_with_receipt(routine.id, "first turn")
      first = correlated_job(initial)
      timeout = if @failure == :timeout, do: 1_500, else: 30_000
      first = prepare_job!(first, binary, timeout)
      worker = worker(provider)
      task = Task.async(fn -> worker.perform(first) end)
      on_exit(fn -> Process.exit(task.pid, :kill) end)

      eventually(fn ->
        assert %{provider_session_id: ^native_id, outcome: nil} =
                 ConversationArcs.read_model(routine.id).current

        assert %{active: %{id: id, provider_session_id: ^native_id}} =
                 ExecutionFacts.read(routine.id)

        assert id == first.id
      end)

      assert Task.yield(task, 0) == nil
      [{old_pid, _state}] = Registry.lookup(registry(provider), routine.id)
      monitor = Process.monitor(old_pid)
      stop_first_turn(task, @failure)
      mark_terminal!(first, "discarded")
      assert Repo.reload!(first).state == "discarded"
      refute Custode.ProviderJobs.active_turn?(routine.id)
      assert :ok = Agents.stop_agent(routine.id, provider)
      assert_receive {:DOWN, ^monitor, :process, ^old_pid, _reason}, 1_000
      refute Process.alive?(old_pid)
      assert {:ok, :offline} = Agents.await(routine.id, provider, :offline, 1_000)
      assert ConversationArcs.read_model(routine.id).current.provider_session_id == native_id

      write_cli!(binary, provider, native_id, :complete)
      assert {:ok, receipt, :created} = continue(routine, @ordering)
      assert receipt.delivery in ~w(started queued admitting delivered)
      second = correlated_job(receipt)
      assert [second.id] == later_job_ids(routine.id, first.id)
      [{new_pid, _state}] = Registry.lookup(registry(provider), routine.id)
      refute new_pid == old_pid
      assert is_binary(first.meta["arc_id"])
      assert is_binary(first.meta["agent_generation"])
      assert is_binary(second.meta["agent_generation"])
      assert second.id != first.id
      assert second.meta["arc_id"] == first.meta["arc_id"]
      assert second.args[resume_key(provider)] == native_id
      assert second.meta["agent_generation"] != first.meta["agent_generation"]
      second = prepare_job!(second, binary, 2_000)
      assert :ok = worker.perform(second)
      mark_terminal!(second, "completed")
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)

      eventually(fn ->
        completed = OperatorMessages.get(receipt.message_id)
        assert completed.status == "completed"
        assert completed.provider_correlation_id == receipt.provider_correlation_id
        assert completed.agent_generation == second.meta["agent_generation"]
        assert completed.arc_id == first.meta["arc_id"]
        expected_delivery = if receipt.delivery == "started", do: "started", else: "delivered"
        assert completed.delivery == expected_delivery
        assert correlated_job(receipt).id == second.id
        assert [second.id] == later_job_ids(routine.id, first.id)
      end)

      arguments = binary |> Kernel.<>(".args") |> File.read!() |> String.split("\n")
      assert native_id in arguments
      assert resume_switch(provider) in arguments
      assert ConversationArcs.read_model(routine.id).current.provider_session_id == native_id
    end
  end

  defp stop_first_turn(task, :timeout) do
    assert {:error, _reason} = Task.await(task, 3_000)
  end

  defp stop_first_turn(task, :worker_killed) do
    assert Task.shutdown(task, :brutal_kill) == nil
    refute Process.alive?(task.pid)
  end

  defp continue(routine, :ordinary),
    do: Actions.message_with_receipt(routine.id, "continue that conversation")

  defp continue(routine, :replay_first) do
    eventually(fn -> assert AgentHandoff.status(routine.id) == :ready end)
    config = Routine.agent_config(routine, ConversationArcs.seed_map(routine))
    coordinator = Process.whereis(AgentHandoff)

    on_exit(fn ->
      if Process.alive?(coordinator), do: :sys.resume(coordinator)
    end)

    :ok = :sys.suspend(coordinator)

    # Suspend admission, not execution. The real replay function admits the
    # durable row before its original caller enters the coordinator callback.
    # Always release the shared coordinator, including assertion failures.
    task =
      Task.async(fn -> Actions.message_with_receipt(routine.id, "continue that conversation") end)

    try do
      eventually(fn ->
        {:messages, messages} = Process.info(coordinator, :messages)

        assert Enum.any?(messages, fn
                 {:"$gen_call", _, {:admit, id, _fun, opts}} ->
                   id == routine.id and opts[:current_queue_head] == true

                 _other ->
                   false
               end)
      end)

      [queued] = OperatorMessages.queued_for(routine.id)
      assert {:ok, _pid} = Agents.start_agent(routine.id, routine.provider, config)
      assert {:ok, :idle} = Agents.await(routine.id, routine.provider, :idle, 1_000)
      assert {:accepted, message_id} = Actions.replay_next(routine.id)
      assert message_id == queued.message_id
    after
      :sys.resume(coordinator)
    end

    assert {:ok, receipt, :created} = Task.await(task, 5_000)
    assert receipt.delivery == "delivered"
    assert AgentHandoff.status(routine.id) == :ready
    {:ok, receipt, :created}
  end

  defp correlated_job(receipt) do
    eventually(fn ->
      assert [job] =
               Repo.all(
                 from(j in Oban.Job,
                   where: j.worker in ["ObanClaude.Agent.Job", "ObanCodex.Agent.Job"],
                   where:
                     fragment("json_extract(?, '$.agent_id')", j.meta) == ^receipt.target_agent_id,
                   where:
                     fragment("json_extract(?, '$.correlation_id')", j.meta) ==
                       ^receipt.provider_correlation_id
                 )
               )

      job
    end)
  end

  defp later_job_ids(agent_id, after_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker in ["ObanClaude.Agent.Job", "ObanCodex.Agent.Job"],
        where: j.id > ^after_id,
        where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^agent_id,
        order_by: j.id,
        select: j.id
      )
    )
  end

  defp prepare_job!(job, binary, timeout) do
    args = Map.merge(job.args, %{"binary" => binary, "timeout" => timeout})
    job |> Ecto.Changeset.change(args: args, state: "executing", attempt: 1) |> Repo.update!()
  end

  defp mark_terminal!(job, state) do
    job |> Repo.reload!() |> Ecto.Changeset.change(state: state) |> Repo.update!()
  end

  defp write_cli!(path, provider, session_id, ending) do
    events = [init(provider, session_id)]
    events = if ending == :complete, do: events ++ result(provider, session_id), else: events

    output =
      Enum.map_join(events, fn event ->
        "printf '%s\\n' '" <> Jason.encode!(event) <> "'\n"
      end)

    # Only fixed test-owned event fields are written to this executable.
    tail = if ending == :block, do: "sleep 30\n", else: "exit 0\n"

    header = ~S"""
    #!/bin/sh
    printf '%s\n' "$@" > "$0.args"
    """

    File.write!(path, header <> output <> tail)
    File.chmod!(path, 0o700)
  end

  defp init(:claude, id), do: %{type: "system", subtype: "init", session_id: id}
  defp init(:codex, id), do: %{type: "thread.started", thread_id: id}

  defp result(:claude, id) do
    [%{type: "result", subtype: "success", is_error: false, session_id: id, result: "done"}]
  end

  defp result(:codex, _id) do
    [
      %{type: "item.completed", item: %{type: "agent_message", text: "done"}},
      %{type: "turn.completed", usage: %{input_tokens: 1, output_tokens: 1}}
    ]
  end

  defp worker(:claude), do: ObanClaude.Agent.Job
  defp worker(:codex), do: ObanCodex.Agent.Job
  defp registry(:claude), do: ObanClaude.Agent.Registry
  defp registry(:codex), do: ObanCodex.Agent.Registry
  defp resume_key(:claude), do: "resume"
  defp resume_key(:codex), do: "session_id"
  defp resume_switch(:claude), do: "--resume"
  defp resume_switch(:codex), do: "resume"
end
