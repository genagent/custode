defmodule Custode.FeedTest do
  # The feed handlers are attached globally at app boot and the path is read
  # per write, so each test points :feed_path at its own tmp file.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias ObanClaude.Agent

  setup do
    path = Path.join(System.tmp_dir!(), uid("feed") <> ".jsonl")
    put_env!(:feed_path, path)

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".1")
    end)

    %{path: path}
  end

  defp job_meta(agent_id), do: %Oban.Job{meta: %{"agent_id" => agent_id}}

  test "a finished run writes a turn entry with directive, summary, and spend" do
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: job_meta("feed-a"),
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => "swept"}, cost_usd: 0.2)
          )
      )

    assert [entry] = Custode.Feed.tail()
    assert %{"event" => "turn", "agent" => "feed-a", "summary" => "swept"} = entry
    assert_in_delta entry["cost_usd"], 0.2, 0.001
  end

  test "a failed run writes a turn_failed entry with the error kind" do
    {{:cancel, :auth}, _} =
      ObanClaude.run(%{"prompt" => "x"}, job: job_meta("feed-b"), query_fun: fail(:auth))

    assert [%{"event" => "turn_failed", "agent" => "feed-b", "kind" => "auth"}] =
             Custode.Feed.tail()
  end

  test "the gated states land with their payloads; pause and resume are recorded" do
    id = start_stub_agent!()

    :processing = Agent.submit_prompt(id, "gated")

    :ok =
      Agent.job_finished(
        id,
        {:ok,
         structured_result(%{"directive" => "request_permission", "action" => "prune old notes"})}
      )

    {:ok, {:awaiting_permission, %{id: action_id}}} =
      Agent.await(id, :awaiting_permission, 1_000)

    :rejected = Agent.reject_action(id, action_id, "test")

    :processing = Agent.submit_prompt(id, "curious")

    :ok =
      Agent.job_finished(
        id,
        {:ok, structured_result(%{"directive" => "ask_user", "question" => "which one?"})}
      )

    {:ok, {:waiting_for_user, _q}} = Agent.await(id, :waiting_for_user, 1_000)

    :ok = Agent.emergency_pause(id)
    {:ok, :paused} = Agent.await(id, :paused, 1_000)
    :resumed = Agent.resume_agent(id)

    events = Custode.Feed.tail() |> Enum.map(&{&1["event"], &1["action"] || &1["question"]})

    assert {"needs_approval", "prune old notes"} in events
    assert {"needs_input", "which one?"} in events
    assert {"paused", nil} in events
    assert {"resumed", nil} in events
  end

  test "the feed rotates to .1 once it crosses feed_max_bytes", %{path: path} do
    put_env!(:feed_max_bytes, 10)

    Custode.Feed.record(%{event: "first"})
    Custode.Feed.record(%{event: "second"})

    assert [%{"event" => "first"}] =
             (path <> ".1")
             |> File.read!()
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    assert [%{"event" => "second"}] = Custode.Feed.tail()
  end

  test "tail/1 bounds and orders; missing file reads as empty" do
    assert Custode.Feed.tail() == []

    for n <- 1..5 do
      {:ok, _} =
        ObanClaude.run(%{"prompt" => "x"},
          job: job_meta("feed-c"),
          query_fun: respond(result(result: "r#{n}", cost_usd: 0.0))
        )
    end

    tail = Custode.Feed.tail(2)
    assert length(tail) == 2
    assert List.last(tail)["summary"] == "r5"
  end
end
