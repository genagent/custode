defmodule Custode.DrainTest do
  # Graceful drain (#132): pause the queues, wait out executing turns, stop.
  # The `:pause`, `:executing` and `:stop` seams are injected so the suite
  # never pauses the real Oban or calls `System.stop/0` on its own VM.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query

  alias Custode.Operator.Actions
  alias Custode.Workflow.{Node, Runner, Stage}

  setup do
    path = Path.join(System.tmp_dir!(), uid("drain-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    put_env!(:oban_queues, ticks: 1, agents: 1, sensors: 1, workflows: 1, custom: 1)

    on_exit(fn ->
      File.rm(path)
      Oban.stop_queue(queue: :ticks)
      await_ticks_stopped()
    end)

    :ok
  end

  # a stateful executing-count seam: each call yields the next step's job list,
  # so a test can script "one turn running, then none".
  defp scripted_executing(steps) do
    {:ok, holder} = Agent.start_link(fn -> steps end)

    fn ->
      Agent.get_and_update(holder, fn
        [head | rest] -> {head, rest}
        [] -> {[], []}
      end)
    end
  end

  test "pauses every queue before waiting, then stops once executing reaches zero" do
    test_pid = self()
    job = %{id: 1, worker: "SomeTurn", queue: "agents"}

    result =
      Custode.drain(
        pause: fn queue -> send(test_pid, {:paused, queue}) end,
        executing: scripted_executing([[job], []]),
        stop: fn -> send(test_pid, :stopped) end,
        poll: 5
      )

    assert result == :ok

    # Every configured queue is included, including additions outside the defaults.
    assert_received {:paused, :ticks}
    assert_received {:paused, :agents}
    assert_received {:paused, :sensors}
    assert_received {:paused, :workflows}
    assert_received {:paused, :custom}

    # and only then, after the running turn cleared, did it stop
    assert_received :stopped
  end

  test "a finite timeout gives up and reports the stuck jobs without stopping" do
    test_pid = self()
    stuck = %{id: 7, worker: "LongTurn", queue: "agents"}

    result =
      Custode.drain(
        pause: fn _queue -> :ok end,
        # never drains
        executing: fn -> [stuck] end,
        stop: fn -> send(test_pid, :stopped) end,
        timeout: 20,
        poll: 5
      )

    assert {:error, {:timeout, [^stuck]}} = result
    refute_received :stopped
  end

  test "the default executing seam reads Oban's executing jobs and clears immediately when idle" do
    test_pid = self()

    # no executing rows in the test db -> the real query returns [] at once
    result =
      Custode.drain(
        pause: fn _queue -> :ok end,
        stop: fn -> send(test_pid, :stopped) end,
        poll: 5
      )

    assert result == :ok
    assert_received :stopped
  end

  test "all pause confirmations precede the first active-work read and async handoff" do
    parent = self()
    queues = [:ticks, :agents, :sensors, :workflows, :custom]
    {:ok, states} = Agent.start_link(fn -> Map.new(queues, &{&1, false}) end)

    put_env!(:drain_fun, fn opts ->
      send(parent, {:background_wait, opts[:queues]})
    end)

    count =
      Custode.start_drain(500,
        pause: fn queue -> send(parent, {:pause_sent, queue}) end,
        check_queue: fn queue ->
          confirmed = Agent.get_and_update(states, &{&1[queue], Map.put(&1, queue, true)})
          send(parent, {:pause_checked, queue, confirmed})
          %{paused: confirmed}
        end,
        executing: fn ->
          for queue <- queues do
            assert_received {:pause_sent, ^queue}
            assert_received {:pause_checked, ^queue, true}
          end

          send(parent, :active_work_read)
          []
        end
      )

    assert count == 0
    assert_received :active_work_read
    assert_receive {:background_wait, ^queues}, 1_000
  end

  test "a workflow completion can enqueue its successor only after workflow admission closes" do
    name = uid("drain-workflow")
    node = fn name -> %Node{name: name, prompt: "fixture", schema: %{"type" => "object"}} end

    workflow =
      Custode.Workflow.new!(name, [
        %Stage{name: :first, nodes: [node.(:first)]},
        %Stage{name: :second, nodes: [node.(:second)]}
      ])

    put_env!(:extra_workflows, %{name => workflow})
    {:ok, run} = Runner.launch(name, "genagent/custode", run_id: uid("drain-run"))
    [first] = workflow_jobs(run.run_id)
    {:ok, state} = Agent.start_link(fn -> %{paused: MapSet.new(), reads: 0} end)
    result = %ClaudeWrapper.Result{result: "finished", extra: %{"structured_output" => %{}}}
    parent = self()

    assert :ok =
             Custode.drain(
               pause: fn queue ->
                 Agent.update(state, &%{&1 | paused: MapSet.put(&1.paused, queue)})
               end,
               check_queue: fn queue ->
                 %{paused: Agent.get(state, &MapSet.member?(&1.paused, queue))}
               end,
               executing: fn ->
                 assert Agent.get(state, &MapSet.member?(&1.paused, :workflows))
                 reads = Agent.get_and_update(state, &{&1.reads, %{&1 | reads: &1.reads + 1}})

                 if reads == 0 do
                   Runner.node_finished(first.meta, result)
                   [%{id: first.id, queue: "workflows", worker: first.worker}]
                 else
                   []
                 end
               end,
               stop: fn -> send(parent, :stopped) end,
               poll: 0
             )

    assert_received :stopped
    assert Enum.any?(workflow_jobs(run.run_id), &(&1.meta["node_name"] == "second"))
    assert Enum.all?(workflow_jobs(run.run_id), &(&1.state == "available"))
    assert Agent.get(state, &MapSet.member?(&1.paused, :workflows))
  end

  test "a pause notification error prevents active reads and async handoff" do
    parent = self()
    put_env!(:drain_fun, fn _opts -> send(parent, :background_wait) end)

    assert {:error, "could not pause queue workflows: :unavailable"} =
             Custode.start_drain(nil,
               queues: [:workflows],
               pause: fn _queue -> {:error, :unavailable} end,
               executing: fn -> send(parent, :active_work_read) end
             )

    refute_received :active_work_read
    refute_received :background_wait
  end

  test "an unconfirmed pause reports admission failure without reading work or stopping" do
    parent = self()

    assert {:error, "queues did not confirm pause: workflows"} =
             Custode.drain(
               queues: [:workflows],
               pause: fn _queue -> :ok end,
               check_queue: fn _queue -> %{paused: false} end,
               pause_timeout: 0,
               executing: fn -> send(parent, :active_work_read) end,
               stop: fn -> send(parent, :stopped) end
             )

    refute_received :active_work_read
    refute_received :stopped
  end

  test "the operator action propagates admission failure" do
    assert {:error, "could not pause queue workflows: :unavailable"} =
             Actions.drain(
               queues: [:workflows],
               pause: fn _queue -> {:error, :unavailable} end
             )
  end

  test "a finite timeout leaves every confirmed queue paused" do
    {:ok, paused} = Agent.start_link(fn -> MapSet.new() end)
    parent = self()
    job = %{id: 7, queue: "workflows", worker: "WorkflowNode"}

    assert {:error, {:timeout, [^job]}} =
             Custode.drain(
               pause: fn queue -> Agent.update(paused, &MapSet.put(&1, queue)) end,
               check_queue: fn queue ->
                 %{paused: Agent.get(paused, &MapSet.member?(&1, queue))}
               end,
               executing: fn -> [job] end,
               stop: fn -> send(parent, :stopped) end,
               timeout: 0
             )

    assert Agent.get(paused, & &1) == MapSet.new([:ticks, :agents, :sensors, :workflows, :custom])
    refute_received :stopped
  end

  defp await_ticks_stopped(attempts \\ 100)
  defp await_ticks_stopped(0), do: flunk("ticks producer did not stop")

  defp await_ticks_stopped(attempts) do
    if Oban.Registry.whereis(Oban, {:producer, "ticks"}) do
      Process.sleep(10)
      await_ticks_stopped(attempts - 1)
    else
      :ok
    end
  end

  defp workflow_jobs(run_id) do
    Custode.Repo.all(
      from(job in Oban.Job,
        where: fragment("json_extract(?, '$.workflow_run')", job.meta) == ^run_id
      )
    )
  end
end
