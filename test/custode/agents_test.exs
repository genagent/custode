defmodule Custode.AgentsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.{AgentHandoff, Agents, OperatorMessages, Routine}
  alias Custode.Feed.Ingest
  alias Custode.Operator.Actions

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

  test "an explicit-provider emergency pause retains the durable pause provenance" do
    id = uid("pause-provenance")

    {:ok, _pid} =
      Agents.start_agent(id,
        enqueue_fun: fn _args, _meta -> {:ok, :queued} end
      )

    on_exit(fn -> Agents.stop_agent(id) end)

    context = %{
      "cause" => "pause_after_turn",
      "reason" => "daily_spend",
      "correlation_id" => "spend-rail-42"
    }

    assert :ok = Agents.emergency_pause(id, :claude, context)
    assert {:ok, :paused} = Agents.await(id, :paused, 1_000)

    assert {:ok,
            %{
              pause_context: %{
                cause: "pause_after_turn",
                pause_reason: "daily_spend",
                correlation_id: "spend-rail-42"
              }
            }} = Agents.info(id, :claude)
  end

  test "a durable message resumes a configured paused routine inside handoff ownership" do
    id = uid("paused-handoff-message")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :claude, cron: :manual, workspace: tmp_workspace!(), prompt: "work"}
    ])

    config =
      id
      |> Routine.get()
      |> Routine.agent_config(%{})
      |> Keyword.put(:enqueue_fun, fn args, meta ->
        send(parent, {:paused_message_enqueued, args, meta})
        {:ok, :queued}
      end)

    {:ok, _pid} = Agents.start_agent(id, :claude, config)
    on_exit(fn -> Agents.stop_agent(id, :claude) end)

    assert :ok = Agents.emergency_pause(id, :claude)
    assert {:ok, :paused} = Agents.await(id, :paused, 1_000)

    assert :ok =
             AgentHandoff.pause(
               id,
               %{cause: :emergency_pause, reason: :operator},
               fn -> :ok end
             )

    assert {:pending, %{phase: :preserving}} = AgentHandoff.status(id)
    :ok = :sys.suspend(AgentHandoff)

    on_exit(fn ->
      if is_pid(Process.whereis(AgentHandoff)), do: :sys.resume(AgentHandoff)
    end)

    delivery =
      Task.async(fn ->
        Actions.message_with_receipt(id, "continue the release",
          actor: %{kind: :operator, id: "test-operator"},
          via: :mcp
        )
      end)

    eventually(fn -> assert [_message] = OperatorMessages.queued_for(id) end)
    :ok = :sys.resume(AgentHandoff)

    assert {:ok, message, :created} = Task.await(delivery, 1_000)

    assert message.delivery == "resumed"

    assert_receive {:paused_message_enqueued, %{"prompt" => prompt}, meta}, 1_000
    assert prompt =~ "continue the release"
    assert meta["correlation_id"] == message.message_id
    assert OperatorMessages.queued_for(id) == []

    :ok = finish_agent_turn(meta, result(session_id: "message-session"))
    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)
    eventually(fn -> assert AgentHandoff.status(id) == :ready end)
    refute_receive {:paused_message_enqueued, _args, _meta}, 100
  end

  test "a Codex routine routes the same lifecycle through ObanCodex" do
    id = uid("codex-facade")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :codex, cron: :manual, workspace: tmp_workspace!(), prompt: "review"}
    ])

    config =
      configured_agent_config(id, fn args, meta ->
        send(parent, {:codex_enqueued, args, meta})
        {:ok, :queued}
      end)

    {:ok, _pid} = Agents.start_agent(id, config)

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

  test "a Codex routine forks a source arc into a distinct target through the facade" do
    id = uid("codex-fork")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :codex, cron: :manual, workspace: tmp_workspace!(), prompt: "review"}
    ])

    config =
      configured_agent_config(id, fn args, meta ->
        send(parent, {:codex_fork_enqueued, args, meta})
        {:ok, :queued}
      end)

    {:ok, _pid} = Agents.start_agent(id, config)

    on_exit(fn -> Agents.stop_agent(id, :codex) end)

    assert :processing = Agents.submit_prompt(id, "first", arc_id: "source")
    assert_receive {:codex_fork_enqueued, %{"prompt" => "first"}, %{"agent_id" => ^id} = meta}

    result = ObanCodex.Testing.result(session_id: "source-thread")
    :ok = ObanCodex.Agent.Job.handle_result(result, %Oban.Job{meta: meta})
    assert Agents.await(id, :idle, 1_000) == {:ok, :idle}

    assert Agents.fork_arc(id, "source", "source", "x") == {:error, :same_arc}
    refute_receive {:codex_fork_enqueued, _args, _meta}, 100

    assert :processing = Agents.fork_arc(id, "source", "alternative", "try another approach")

    assert_receive {:codex_fork_enqueued,
                    %{
                      "prompt" => "try another approach",
                      "session_id" => "source-thread",
                      "fork_session" => true
                    }, %{"agent_id" => ^id} = fork_meta}

    fork_result = ObanCodex.Testing.result(session_id: "alternative-thread")
    :ok = ObanCodex.Agent.Job.handle_result(fork_result, %Oban.Job{meta: fork_meta})
    assert Agents.await(id, :idle, 1_000) == {:ok, :idle}

    assert {:ok, info} = Agents.info(id)

    assert info.session_arcs == %{
             "source" => "source-thread",
             "alternative" => "alternative-thread"
           }
  end

  test "a Codex permission request opens the shared gate" do
    id = uid("codex-gate")
    parent = self()

    put_env!(:routines, [
      %{id: id, provider: :codex, cron: :manual, workspace: tmp_workspace!(), prompt: "review"}
    ])

    config =
      configured_agent_config(id, fn args, meta ->
        send(parent, {:codex_gate_enqueued, args, meta})
        {:ok, :queued}
      end)

    {:ok, _pid} = Agents.start_agent(id, config)

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

  defp configured_agent_config(id, enqueue_fun) do
    id
    |> Routine.get()
    |> Routine.agent_config(%{})
    |> Keyword.put(:enqueue_fun, enqueue_fun)
  end
end
