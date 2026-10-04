defmodule Custode.EarlySessionRecoveryTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{Agents, ConversationArcs, ExecutionFacts, Repo}
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

  for provider <- [:claude, :codex], failure <- [:timeout, :worker_killed] do
    @provider provider
    @failure failure
    @tag provider: provider

    test "#{provider} resumes its early handle after #{failure} and an agent restart" do
      provider = @provider
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{provider: provider, cron: :manual})
      on_exit(fn -> Agents.stop_agent(routine.id, provider) end)
      binary = Path.join(workspace, "fake-provider")
      native_id = uid("native")
      write_cli!(binary, provider, native_id, :block)

      assert {:ok, :started} = Actions.message(routine.id, "first turn")
      first = latest_job(routine.id)
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
      stop_first_turn(task, @failure)
      mark_terminal!(first, "discarded")
      assert :ok = Agents.stop_agent(routine.id, provider)
      assert ConversationArcs.read_model(routine.id).current.provider_session_id == native_id

      write_cli!(binary, provider, native_id, :complete)
      assert {:ok, delivery} = Actions.message(routine.id, "continue that conversation")
      assert delivery in [:started, :queued]
      second = latest_job(routine.id, first.id)
      assert second.id != first.id
      assert second.meta["arc_id"] == first.meta["arc_id"]
      assert (second.args["resume"] || second.args["session_id"]) == native_id
      assert second.meta["agent_generation"] != first.meta["agent_generation"]
      second = prepare_job!(second, binary, 2_000)
      assert :ok = worker.perform(second)
      mark_terminal!(second, "completed")
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)

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

  defp latest_job(agent_id, after_id \\ 0) do
    eventually(fn ->
      job =
        Repo.one(
          from(j in Oban.Job,
            where: j.worker in ["ObanClaude.Agent.Job", "ObanCodex.Agent.Job"],
            where: j.id > ^after_id,
            where: fragment("json_extract(?, '$.agent_id')", j.meta) == ^agent_id,
            order_by: [desc: j.id],
            limit: 1
          )
        )

      assert %Oban.Job{} = job
      job
    end)
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
  defp resume_switch(:claude), do: "--resume"
  defp resume_switch(:codex), do: "resume"
end
