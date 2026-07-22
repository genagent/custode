defmodule Custode.DrainTest do
  # Graceful drain (#132): pause the queues, wait out executing turns, stop.
  # The `:pause`, `:executing` and `:stop` seams are injected so the suite
  # never pauses the real Oban or calls `System.stop/0` on its own VM.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  setup do
    path = Path.join(System.tmp_dir!(), uid("drain-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
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

    # all three queues paused up front (no new turn can start during the wait)
    assert_received {:paused, :ticks}
    assert_received {:paused, :agents}
    assert_received {:paused, :sensors}

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
end
