defmodule Custode.PubSubBridgeTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias ObanClaude.Agent

  setup do
    :ok = Custode.PubSubBridge.subscribe()

    path = Path.join(System.tmp_dir!(), uid("bridge-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  test "every agent transition broadcasts a status_changed nudge" do
    id = start_stub_agent!()
    :processing = Agent.submit_prompt(id, "turn")

    assert_receive {:status_changed, ^id}

    assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

    :ok = finish_agent_turn(turn_meta, result("done"))
    assert_receive {:status_changed, ^id}
  end

  test "feed entries ride the same topic, in the tail/1 string-key shape" do
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => "bridge-a"}},
        query_fun:
          respond(
            structured_result(%{"directive" => "none", "summary" => "swept"}, cost_usd: 0.1)
          )
      )

    assert_receive {:feed_entry, entry}
    assert %{"event" => "turn", "agent" => "bridge-a", "summary" => "swept"} = entry
  end
end
