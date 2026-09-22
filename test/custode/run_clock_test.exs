defmodule Custode.RunClockTest do
  # The in-flight clock (#211): a run start records the agent, a stop clears
  # it -- through the real oban_claude telemetry, so running/0 is the live
  # set of executing turns.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  setup do
    path = Path.join(System.tmp_dir!(), uid("rc-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "a run marks the agent in flight for its duration, then clears it" do
    agent = uid("rc")
    refute Map.has_key?(Custode.RunClock.running(), agent)

    # a query_fun that checks the clock DURING the run (run.start fires
    # before it): the agent is recorded in flight
    test_pid = self()

    query_fun = fn _prompt, _opts ->
      send(test_pid, {:in_flight?, Map.has_key?(Custode.RunClock.running(), agent)})
      {:ok, ObanClaude.Testing.result("done")}
    end

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: query_fun
      )

    assert_received {:in_flight?, true}

    # ...and cleared once the run stops
    refute Map.has_key?(Custode.RunClock.running(), agent)
  end

  test "an exception clears the in-flight entry too" do
    agent = uid("rc-fail")

    {{:error, :command_failed}, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun:
          ObanClaude.Testing.fail(ObanClaude.Testing.error(:command_failed, message: "boom"))
      )

    refute Map.has_key?(Custode.RunClock.running(), agent)
  end

  test "a Codex run uses the same in-flight clock" do
    agent = uid("rc-codex")
    test_pid = self()

    query_fun = fn _prompt, _opts ->
      send(test_pid, {:codex_in_flight?, Map.has_key?(Custode.RunClock.running(), agent)})
      {:ok, ObanCodex.Testing.result("done")}
    end

    {:ok, _} =
      ObanCodex.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "tick"}},
        query_fun: query_fun
      )

    assert_received {:codex_in_flight?, true}
    refute Map.has_key?(Custode.RunClock.running(), agent)
  end

  test "a gate review does not make the gated author look like it is running" do
    agent = uid("rc-review")

    :ok =
      Custode.RunClock.handle_event(
        [:oban_codex, :run, :start],
        %{},
        %{job: %{meta: %{"agent_id" => agent, "custode_kind" => "gate_review"}}},
        nil
      )

    refute Map.has_key?(Custode.RunClock.running(), agent)
  end
end
