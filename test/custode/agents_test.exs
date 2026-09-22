defmodule Custode.AgentsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Agents
  alias Custode.Feed.Ingest

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

  test "a Codex routine routes the same lifecycle through ObanCodex" do
    id = uid("codex-facade")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :codex, cron: :manual, workspace: tmp_workspace!(), prompt: "review"}
    ])

    {:ok, _pid} =
      Agents.start_agent(id,
        enqueue_fun: fn args, meta ->
          send(parent, {:codex_enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agents.stop_agent(id, :codex) end)

    assert Agents.provider(id) == :codex
    assert :processing = Agents.submit_prompt(id, "review this")

    assert_receive {:codex_enqueued, %{"prompt" => "review this"},
                    %{"agent_id" => ^id, "origin" => "operator"} = meta}

    result = ObanCodex.Testing.result(session_id: "codex-thread")
    :ok = ObanCodex.Agent.Job.handle_result(result, %Oban.Job{meta: meta})
    assert Agents.await(id, :idle, 1_000) == {:ok, :idle}
    assert {id, :idle} in Agents.list()

    assert :processing = Agents.submit_prompt(id, "continue", session: :resume)

    assert_receive {:codex_enqueued, %{"prompt" => "continue", "session_id" => "codex-thread"},
                    %{"agent_id" => ^id}}
  end

  test "a Codex permission request opens the shared gate" do
    id = uid("codex-gate")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :codex, cron: :manual, workspace: tmp_workspace!(), prompt: "review"}
    ])

    {:ok, _pid} =
      Agents.start_agent(id,
        enqueue_fun: fn args, meta ->
          send(parent, {:codex_gate_enqueued, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agents.stop_agent(id, :codex) end)

    assert :processing = Agents.submit_prompt(id, "review this")
    assert_receive {:codex_gate_enqueued, _args, %{"agent_id" => ^id} = meta}

    result =
      ObanCodex.Testing.structured_result(%{
        "directive" => "request_permission",
        "action" => "open the review PR",
        "action_class" => "implement"
      })

    :ok =
      Ingest.handle_event(
        [:oban_codex, :run, :stop],
        %{cost_usd: 0.0},
        %{result: result, job: %{meta: meta}},
        nil
      )

    :ok = ObanCodex.Agent.Job.handle_result(result, %Oban.Job{meta: meta})
    assert {:ok, {:awaiting_permission, _payload}} = Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert [%{detail: "open the review PR", class: "implement"}] =
               Custode.Gates.open_gates(id)
    end)
  end
end
