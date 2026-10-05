defmodule Custode.SubprocessCleanupTest do
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Error, Result}

  @fixture Path.expand("../fixtures/subprocess_cli.py", __DIR__)

  setup do
    dir = Path.join(System.tmp_dir!(), Custode.TestHelpers.uid("subprocess"))
    File.mkdir_p!(dir)
    binary = Path.join(dir, "claude")
    File.cp!(@fixture, binary)
    File.chmod!(binary, 0o755)

    on_exit(fn ->
      # Only the PIDs recorded by this fixture are eligible for cleanup.
      for pid <- pids(dir), alive?(pid), do: System.cmd("kill", ["-TERM", pid])
      File.rm_rf!(dir)
    end)

    %{dir: dir, binary: binary}
  end

  test "the configured routine runner is compiled and preserves successful results", context do
    assert ClaudeWrapper.Runner.impl() == Custode.Workflow.ClaudeRunner
    assert Code.ensure_loaded?(Custode.Workflow.ClaudeRunner)
    assert Code.ensure_loaded?(ClaudeWrapper.Runner.Forcola)
    File.touch!(Path.join(context.dir, "success"))

    job = job(context, 5_000)
    assert :ok = ObanClaude.Agent.Job.perform(job)

    assert {:ok, %Result{result: "finished", session_id: "fake-session"}} =
             ClaudeWrapper.query("fixture", binary: context.binary, working_dir: context.dir)
  end

  test "a worker timeout preserves the typed error and stops later child writes", context do
    parent = self()
    handler = "cleanup-#{Custode.TestHelpers.uid("telemetry")}"

    :telemetry.attach(
      handler,
      [:oban_claude, :run, :exception],
      fn _, _, meta, _ ->
        send(parent, {:wrapper_error, meta.error})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:error, :timeout} = ObanClaude.Agent.Job.perform(job(context, 500))
    assert_receive {:wrapper_error, %Error{kind: :timeout}}
    assert_stopped(context.dir)
  end

  test "a continuously emitting stream obeys the deadline and stops its child", context do
    assert ClaudeWrapper.Runner.impl() == Custode.Workflow.ClaudeRunner
    File.touch!(Path.join(context.dir, "stream"))

    task =
      Task.async(fn ->
        "fixture"
        |> ClaudeWrapper.stream(
          binary: context.binary,
          working_dir: context.dir,
          timeout: 500
        )
        |> Enum.to_list()
      end)

    on_exit(fn -> if Process.alive?(task.pid), do: Process.exit(task.pid, :kill) end)
    outcome = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert {:ok, events} = outcome
    assert Enum.any?(events, &(&1.type == "system"))
    assert %{type: "error", data: %{"error" => "stream_truncated"}} = List.last(events)
    assert_stopped(context.dir)
  end

  test "terminating the worker owner stops its CLI and child", context do
    owner = spawn(fn -> ObanClaude.Agent.Job.perform(job(context, 30_000)) end)
    on_exit(fn -> if Process.alive?(owner), do: Process.exit(owner, :kill) end)
    assert eventually(fn -> length(pids(context.dir)) == 2 end)
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_stopped(context.dir)
  end

  defp job(context, timeout) do
    %Oban.Job{
      args: %{
        "prompt" => "fixture",
        "binary" => context.binary,
        "working_dir" => context.dir,
        "timeout" => timeout
      },
      attempt: 1,
      max_attempts: 1,
      meta: %{}
    }
  end

  defp assert_stopped(dir) do
    tracked = pids(dir)
    assert length(tracked) == 2
    assert eventually(fn -> Enum.all?(tracked, &(not alive?(&1))) end)
    Process.sleep(2_100)
    refute File.exists?(Path.join(dir, "late-write"))
  end

  defp pids(dir) do
    case File.read(Path.join(dir, "pids")) do
      {:ok, value} -> String.split(value)
      {:error, :enoent} -> []
    end
  end

  defp alive?(pid) do
    case System.cmd("ps", ["-p", pid, "-o", "stat="]) do
      {state, 0} -> String.trim(state) != "" and not String.starts_with?(String.trim(state), "Z")
      {_, _} -> false
    end
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, remaining) do
    if fun.() do
      true
    else
      Process.sleep(50)
      eventually(fun, remaining - 1)
    end
  end
end
