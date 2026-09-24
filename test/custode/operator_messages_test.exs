defmodule Custode.OperatorMessagesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Agents, OperatorMessage, OperatorMessages, Repo}

  setup do
    Repo.delete_all(OperatorMessage)
    :ok
  end

  test "concurrent retries deliver once and a changed prompt conflicts" do
    parent = self()
    target = uid("dedupe-target")
    caller = %{kind: :operator, id: uid("caller")}

    deliver = fn _correlation_id ->
      send(parent, :delivered)
      Process.sleep(25)
      {:ok, :delivered}
    end

    results =
      1..8
      |> Task.async_stream(
        fn _ ->
          OperatorMessages.submit(
            target,
            "inspect the release",
            [actor: caller, idempotency_key: "release-1"],
            deliver
          )
        end,
        max_concurrency: 8,
        ordered: false,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert_receive :delivered
    refute_receive :delivered, 100

    assert [message_id] =
             results
             |> Enum.map(fn {:ok, message, _disposition} -> message.message_id end)
             |> Enum.uniq()

    assert Enum.count(results, &match?({:ok, _message, :created}, &1)) == 1
    assert Enum.count(results, &match?({:ok, _message, :duplicate}, &1)) == 7

    assert {:error, :idempotency_conflict} =
             OperatorMessages.submit(
               target,
               "publish it instead",
               [actor: caller, idempotency_key: "release-1"],
               deliver
             )

    assert OperatorMessages.get(message_id).status == "queued"
  end

  test "delivery refusal is durable and exact await returns it immediately" do
    assert {:error, {:refused, message, :agent_not_running}} =
             OperatorMessages.submit(uid("missing"), "hello", [], fn _correlation_id ->
               {:error, :agent_not_running}
             end)

    assert message.status == "refused"
    assert message.error["kind"] == "delivery_refused"
    assert {:ok, settled, false} = OperatorMessages.await(message.message_id, 0)
    assert settled.status == "refused"
  end

  test "await on an unsettled exact message times out with its current state" do
    assert {:ok, message, :created} =
             OperatorMessages.submit(uid("slow"), "keep working", [], fn _correlation_id ->
               {:ok, :delivered}
             end)

    assert {:ok, current, true} = OperatorMessages.await(message.message_id, 0)
    assert current.status == "queued"
  end

  for provider <- [:claude, :codex] do
    @provider provider

    test "#{provider} queues preserve exact identities and outcomes" do
      provider = @provider
      id = start_provider_agent!(provider)

      assert {:ok, first, :created} = send_message(id, "first")
      assert_receive {:provider_enqueued, ^provider, _args, first_meta}
      assert first_meta["correlation_id"] == first.message_id

      assert {:ok, second, :created} = send_message(id, "second")
      assert OperatorMessages.get(second.message_id).status == "queued"
      refute_receive {:provider_enqueued, ^provider, _args, _meta}, 100

      finish(provider, first_meta, result(provider, "first done", "session-one"))

      assert_receive {:provider_enqueued, ^provider, _args, second_meta}
      assert second_meta["correlation_id"] == second.message_id

      eventually(fn ->
        assert %{status: "completed"} = OperatorMessages.get(first.message_id)
        assert OperatorMessages.get(second.message_id).status == "executing"
      end)

      assert {:ok, exact_second, true} = OperatorMessages.await(second.message_id, 0)
      assert exact_second.status == "executing"
      assert exact_second.agent_generation == second_meta["agent_generation"]
      assert exact_second.agent_turn_id == second_meta["agent_turn_id"]
      assert exact_second.arc_id == second_meta["arc_id"]

      finish(provider, second_meta, result(provider, "second done", "session-two"))
      assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

      assert {:ok, completed, false} = OperatorMessages.await(second.message_id, 1_000)
      assert completed.status == "completed"
      assert completed.provider == to_string(provider)
      assert completed.provider_session_id == "session-two"
      assert completed.result == %{"output" => "second done"}
      assert completed.completed_at
    end
  end

  test "a question and its answer share provider correlation but keep public provenance" do
    id = start_provider_agent!(:claude)

    assert {:ok, request, :created} = send_message(id, "choose a target")
    assert_receive {:provider_enqueued, :claude, _args, request_meta}

    finish(
      :claude,
      request_meta,
      ObanClaude.Testing.structured_result(
        %{"directive" => "ask_user", "question" => "staging or production?"},
        session_id: "question-session"
      )
    )

    assert {:ok, {:waiting_for_user, "staging or production?"}} =
             Agents.await(id, :waiting_for_user, 1_000)

    eventually(fn ->
      assert %{status: "waiting_for_input", detail: "staging or production?"} =
               OperatorMessages.get(request.message_id)
    end)

    assert {:ok, answer, :created} = send_message(id, "staging")
    assert answer.message_id != request.message_id
    assert answer.provider_correlation_id == request.message_id
    assert answer.continues_message_id == request.message_id
    assert_receive {:provider_enqueued, :claude, _args, answer_meta}
    assert answer_meta["correlation_id"] == request.message_id

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "executing"
      assert OperatorMessages.get(answer.message_id).status == "executing"
    end)

    finish(:claude, answer_meta, result(:claude, "target recorded", "answer-session"))
    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

    eventually(fn ->
      for message_id <- [request.message_id, answer.message_id] do
        assert %{status: "completed", provider_session_id: "answer-session"} =
                 OperatorMessages.get(message_id)
      end
    end)
  end

  test "an approval continuation retains the original message correlation" do
    id = start_provider_agent!(:codex)

    assert {:ok, request, :created} = send_message(id, "prepare the change")
    assert_receive {:provider_enqueued, :codex, _args, request_meta}

    finish(
      :codex,
      request_meta,
      ObanCodex.Testing.structured_result(
        %{"directive" => "request_permission", "action" => "merge the change"},
        session_id: "gate-session"
      )
    )

    assert {:ok, {:awaiting_permission, %{id: action_id}}} =
             Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert %{status: "waiting_for_approval", detail: "merge the change"} =
               OperatorMessages.get(request.message_id)
    end)

    assert :processing = Agents.approve_action(id, action_id)
    assert_receive {:provider_enqueued, :codex, _args, approval_meta}
    assert approval_meta["correlation_id"] == request.message_id

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "executing"
    end)

    finish(:codex, approval_meta, result(:codex, "merged", "approved-session"))
    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "completed"
    end)
  end

  test "a terminal provider failure is projected onto the exact message" do
    id = start_provider_agent!(:claude)

    assert {:ok, request, :created} = send_message(id, "attempt the work")
    assert_receive {:provider_enqueued, :claude, _args, meta}

    assert {:cancel, :auth} =
             ObanClaude.Agent.Job.handle_error(
               {:cancel, :auth},
               :credential_rejected,
               %Oban.Job{meta: meta, attempt: 1, max_attempts: 1}
             )

    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

    eventually(fn ->
      assert %{status: "failed", error: %{"kind" => "failed"}} =
               OperatorMessages.get(request.message_id)
    end)
  end

  test "restart reconciliation recovers durable jobs and fails orphaned deliveries" do
    assert {:ok, orphan, :created} = queued_message(uid("orphan"))
    assert {:ok, durable, :created} = queued_message(uid("durable"))

    now = DateTime.utc_now()

    job =
      %{"prompt" => "resume"}
      |> Oban.Job.new(
        worker: ObanClaude.Agent.Job,
        queue: :agents,
        meta: %{
          "correlation_id" => durable.provider_correlation_id,
          "agent_generation" => "generation-1",
          "agent_turn_id" => "turn-1",
          "arc_id" => "arc-1"
        }
      )
      |> Repo.insert!()

    :ok = OperatorMessages.reconcile!()

    assert %{status: "failed", error: %{"kind" => "delivery_interrupted"}} =
             OperatorMessages.get(orphan.message_id)

    assert %{status: "queued", agent_turn_id: "turn-1"} =
             OperatorMessages.get(durable.message_id)

    job
    |> Ecto.Changeset.change(state: "executing", attempted_at: now)
    |> Repo.update!()

    :ok = OperatorMessages.reconcile!()

    assert %{status: "executing", started_at: ^now} =
             OperatorMessages.get(durable.message_id)
  end

  test "a recovered provider job cannot claim application completion without its live owner" do
    assert {:ok, message, :created} = queued_message(uid("recovered"))

    meta = %{
      "agent_id" => message.target_agent_id,
      "agent_generation" => "dead-generation",
      "agent_turn_id" => "dead-turn",
      "arc_id" => "dead-arc",
      "correlation_id" => message.provider_correlation_id
    }

    result = ObanClaude.Testing.result("provider finished")

    :telemetry.execute(
      [:oban_claude, :run, :stop],
      %{duration: 1, cost_usd: 0.0},
      %{result: result, args: %{}, job: %{meta: meta}}
    )

    assert %{
             status: "failed",
             result: %{"output" => "provider finished"},
             error: %{"kind" => "delivery_interrupted"}
           } = OperatorMessages.get(message.message_id)
  end

  defp start_provider_agent!(provider) do
    id = uid("#{provider}-message")
    parent = self()

    put_env!(:routines, [
      %{
        id: id,
        provider: provider,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "work"
      }
    ])

    {:ok, _pid} =
      Agents.start_agent(id,
        enqueue_fun: fn args, meta ->
          send(parent, {:provider_enqueued, provider, args, meta})
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agents.stop_agent(id, provider) end)
    id
  end

  defp send_message(agent_id, prompt) do
    OperatorMessages.submit(
      agent_id,
      prompt,
      [actor: %{kind: :operator, id: "test-operator"}, via: :mcp],
      fn correlation_id ->
        case Agents.cast_prompt(agent_id, prompt, correlation_id: correlation_id) do
          :ok -> {:ok, :delivered}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp queued_message(target) do
    OperatorMessages.submit(target, "queued", [], fn _correlation_id ->
      {:ok, :delivered}
    end)
  end

  defp finish(provider, meta, result) do
    :telemetry.execute(
      [telemetry_provider(provider), :run, :stop],
      %{duration: 1, cost_usd: 0.0},
      %{result: result, args: %{}, job: %{meta: meta}}
    )

    job = %Oban.Job{meta: meta, attempt: 1, max_attempts: 1}

    case provider do
      :claude -> ObanClaude.Agent.Job.handle_result(result, job)
      :codex -> ObanCodex.Agent.Job.handle_result(result, job)
    end
  end

  defp telemetry_provider(:claude), do: :oban_claude
  defp telemetry_provider(:codex), do: :oban_codex

  defp result(:claude, output, session_id),
    do: ObanClaude.Testing.result(result: output, session_id: session_id)

  defp result(:codex, output, session_id),
    do: ObanCodex.Testing.result(output, session_id: session_id)
end
