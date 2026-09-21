defmodule Custode.AgentsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Agents

  test "queued casts stay nonblocking and preserve session, origin and agent identity" do
    id = uid("facade")
    parent = self()

    {:ok, _pid} =
      Agents.start_agent(id,
        enqueue_fun: fn args, meta ->
          send(parent, {:enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agents.stop_agent(id) end)

    assert :processing = Agents.submit_prompt(id, "first")

    assert_receive {:enqueued, %{"prompt" => "first"},
                    %{"agent_id" => ^id, "origin" => "operator"} = turn_meta}

    # A synchronous submit here would block behind the running turn. Fresh
    # session options must also survive that queue, not just an idle cast.
    queued = Task.async(fn -> Agents.cast_prompt(id, "next", session: :fresh, origin: :tick) end)
    assert Task.await(queued, 500) == :ok
    refute_receive {:enqueued, _, _}

    :ok = finish_agent_turn(turn_meta, result(session_id: "first-session"))
    assert_receive {:enqueued, next_args, %{"agent_id" => ^id, "origin" => "tick"} = turn_meta}
    assert next_args["prompt"] == "next"
    refute Map.has_key?(next_args, "resume")

    :ok = finish_agent_turn(turn_meta, result(session_id: "second-session"))
    assert Agents.await(id, :idle, 1_000) == {:ok, :idle}

    assert :processing = Agents.submit_prompt(id, "last", session: :resume, origin: :operator)

    assert_receive {:enqueued, %{"prompt" => "last", "resume" => "second-session"},
                    %{"agent_id" => ^id, "origin" => "operator"}}
  end
end
