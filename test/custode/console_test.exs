defmodule Custode.ConsoleTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias ObanClaude.Agent

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{workspace: workspace, routine: routine}
  end

  # Replace the offline routine agent with a same-id stub the test can observe.
  defp stub_routine_agent!(routine) do
    test_pid = self()

    enqueue_fun = fn args, meta ->
      send(test_pid, {:enqueued, args, meta})
      {:ok, :queued}
    end

    {:ok, _pid} = Agent.start_agent(routine.id, enqueue_fun: enqueue_fun)
    on_exit(fn -> Agent.stop_agent(routine.id) end)
    :ok
  end

  test "note/1 drops a timestamped file in the routine's inbox", %{workspace: workspace} do
    {:ok, path} = Custode.note("remember the milk")

    assert Path.dirname(path) == Path.join(workspace, "inbox")
    assert File.read!(path) == "remember the milk\n"
  end

  test "beat/0 inserts a Tick with the routine's full spec (which never runs in test)",
       %{routine: routine} do
    {:ok, job_id} = Custode.beat()

    [job] = jobs_for("ObanClaude.Agent.Tick") |> Enum.filter(&(&1.id == job_id))
    assert job.queue == "ticks"
    assert job.args["agent_id"] == routine.id
    assert job.args["if_offline"] == "start"
  end

  test "poke and ask deliver prompts to the routine agent", %{routine: routine} do
    stub_routine_agent!(routine)

    assert :ok = Custode.poke("do a thing")
    assert_receive {:enqueued, %{"prompt" => "do a thing"}, _meta}
    :ok = Agent.job_finished(routine.id, {:ok, result("done")})
    {:ok, :idle} = Agent.await(routine.id, :idle, 1_000)

    assert :processing = Custode.ask("another thing")
    assert_receive {:enqueued, %{"prompt" => "another thing"}, _meta}
  end

  test "approve/0 releases the pending gate; reject/1 records the denial",
       %{routine: routine} do
    stub_routine_agent!(routine)

    gate = fn ->
      :processing = Custode.ask("gated work")
      assert_receive {:enqueued, _args, _meta}

      :ok =
        Agent.job_finished(
          routine.id,
          {:ok, structured_result(%{"directive" => "request_permission", "action" => "do it"})}
        )

      {:ok, {:awaiting_permission, _action}} =
        Agent.await(routine.id, :awaiting_permission, 1_000)
    end

    gate.()
    assert :processing = Custode.approve()
    assert_receive {:enqueued, %{"prompt" => prompt}, _meta}
    assert prompt =~ "do it"
    :ok = Agent.job_finished(routine.id, {:ok, result("did it")})
    {:ok, :idle} = Agent.await(routine.id, :idle, 1_000)

    gate.()
    assert :rejected = Custode.reject("nope")
    {:ok, history} = Agent.history(routine.id)
    assert Enum.any?(history, &match?({:denied, _id, "nope"}, &1))
  end

  test "approve/0 with nothing pending reports what it found instead", %{routine: routine} do
    stub_routine_agent!(routine)
    assert {:error, {:nothing_pending, :idle}} = Custode.approve()
  end

  test "pause/0 and resume/0 drive the lockdown", %{routine: routine} do
    stub_routine_agent!(routine)

    :ok = Custode.pause()
    {:ok, :paused} = Agent.await(routine.id, :paused, 1_000)
    assert {:error, :paused} = Custode.ask("while locked")
    assert :resumed = Custode.resume()
    assert {:ok, :idle} = Custode.status()
  end

  test "peek/1 renders the offline hint and the live snapshot", %{routine: routine} do
    import ExUnit.CaptureIO

    assert capture_io(fn -> Custode.peek() end) =~ "offline"

    stub_routine_agent!(routine)
    :processing = Custode.ask("turn")
    :ok = Agent.job_finished(routine.id, {:ok, result(result: "done", cost_usd: 0.5)})
    {:ok, :idle} = Agent.await(routine.id, :idle, 1_000)

    output = capture_io(fn -> Custode.peek() end)
    assert output =~ ":idle"
    assert output =~ "turns=1"
    assert output =~ "$0.5"
  end
end
