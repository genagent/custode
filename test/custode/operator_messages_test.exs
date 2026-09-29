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
    assert message.delivery == "refused"
    assert message.error["kind"] == "delivery_refused"
    assert {:ok, settled, false} = OperatorMessages.await(message.message_id, 0)
    assert settled.status == "refused"
    assert settled.delivery == "refused"
  end

  test "await on an unsettled exact message times out with its current state" do
    assert {:ok, message, :created} =
             OperatorMessages.submit(uid("slow"), "keep working", [], fn _correlation_id ->
               {:ok, :delivered}
             end)

    assert {:ok, current, true} = OperatorMessages.await(message.message_id, 0)
    assert current.status == "queued"
  end

  test "caller-scoped listing filters durable messages and exposes only a compact summary" do
    caller = %{kind: :operator, id: uid("listing-caller")}
    other_caller = %{kind: :operator, id: uid("other-caller")}
    first_target = uid("first-target")
    second_target = uid("second-target")
    long_prompt = String.duplicate("private context ", 20)

    assert {:ok, first, :created} =
             OperatorMessages.submit(
               first_target,
               long_prompt,
               [actor: caller, idempotency_key: "private-idempotency-key"],
               fn _message -> {:ok, :queued} end
             )

    completed_at = DateTime.utc_now()

    first =
      first
      |> Ecto.Changeset.change(
        status: "completed",
        result: %{"output" => "private result"},
        completed_at: completed_at
      )
      |> Repo.update!()

    assert {:ok, second, :created} =
             OperatorMessages.submit(
               second_target,
               "newer message",
               [actor: caller, idempotency_key: "newer"],
               fn _message -> {:ok, :queued} end
             )

    assert {:ok, _other, :created} =
             OperatorMessages.submit(
               first_target,
               "another caller's message",
               [actor: other_caller, idempotency_key: "other"],
               fn _message -> {:ok, :queued} end
             )

    assert [^second, ^first] = OperatorMessages.list_for(caller)

    assert [^first] =
             OperatorMessages.list_for(caller,
               agent_id: first_target,
               status: "completed",
               limit: 1
             )

    summary = OperatorMessages.public_summary(first)

    assert summary.message_id == first.message_id
    assert summary.agent_id == first_target
    assert summary.status == "completed"
    assert String.length(summary.prompt_preview) == 160
    assert summary.completed_at == DateTime.to_iso8601(completed_at)

    encoded = Jason.encode!(summary)
    refute encoded =~ "private-idempotency-key"
    refute encoded =~ "private result"
    refute encoded =~ long_prompt
    refute Map.has_key?(summary, :result)
    refute Map.has_key?(summary, :error)
    refute Map.has_key?(summary, :provider_turn)
  end

  describe "conversation/2" do
    test "scopes direct operator exchanges to one target and returns them oldest first" do
      target = uid("conversation-target")
      other_target = uid("conversation-other")

      older =
        conversation_message!(target, "first operator prompt", %{
          kind: :operator,
          id: "operator-one"
        })

      _delegated =
        conversation_message!(target, "delegated prompt must stay out", %{
          kind: :routine,
          id: "delegating-agent"
        })

      _other =
        conversation_message!(other_target, "other target must stay out", %{
          kind: :operator,
          id: "operator-one"
        })

      newer =
        conversation_message!(target, "second operator prompt", %{
          kind: :operator,
          id: "operator-two"
        })

      assert {:ok, %{exchanges: exchanges, before: nil, has_older: false}} =
               OperatorMessages.conversation(target)

      assert Enum.map(exchanges, & &1.id) == [
               older.provider_correlation_id,
               newer.provider_correlation_id
             ]

      assert Enum.map(exchanges, fn exchange ->
               Enum.map(exchange.prompts, & &1.text)
             end) == [["first operator prompt"], ["second operator prompt"]]
    end

    test "pages complete correlation groups without duplicates or gaps" do
      target = uid("conversation-pages")
      actor = %{kind: :operator, id: "operator"}

      oldest = conversation_message!(target, "oldest exchange", actor)
      question = conversation_message!(target, "question exchange", actor)

      question
      |> Ecto.Changeset.change(
        status: "waiting_for_input",
        detail: "which environment?"
      )
      |> Repo.update!()

      continuation = conversation_message!(target, "staging", actor)
      assert continuation.provider_correlation_id == question.provider_correlation_id
      assert continuation.continues_message_id == question.message_id

      completed_at = DateTime.utc_now()

      for message <- [question, continuation] do
        message
        |> Ecto.Changeset.change(status: "completed", completed_at: completed_at)
        |> Repo.update!()
      end

      newest = conversation_message!(target, "newest exchange", actor)

      assert {:ok,
              %{
                exchanges: [%{id: newest_id}],
                before: first_cursor,
                has_older: true
              }} = OperatorMessages.conversation(target, limit: 1)

      assert newest_id == newest.provider_correlation_id
      assert is_binary(first_cursor)

      assert {:ok,
              %{
                exchanges: [continued_exchange],
                before: second_cursor,
                has_older: true
              }} = OperatorMessages.conversation(target, limit: 1, before: first_cursor)

      assert continued_exchange.id == question.provider_correlation_id
      assert Enum.map(continued_exchange.prompts, & &1.text) == ["question exchange", "staging"]
      assert is_binary(second_cursor)

      assert {:ok,
              %{
                exchanges: [%{id: oldest_id}],
                before: nil,
                has_older: false
              }} = OperatorMessages.conversation(target, limit: 1, before: second_cursor)

      assert oldest_id == oldest.provider_correlation_id

      assert Enum.uniq([oldest_id, continued_exchange.id, newest_id]) == [
               oldest.provider_correlation_id,
               question.provider_correlation_id,
               newest.provider_correlation_id
             ]
    end

    test "rejects malformed cursors and cursors scoped to another agent" do
      first_target = uid("conversation-cursor-first")
      second_target = uid("conversation-cursor-second")
      actor = %{kind: :operator, id: "operator"}

      _older = conversation_message!(first_target, "older", actor)
      _newer = conversation_message!(first_target, "newer", actor)

      assert {:ok, %{before: cursor, has_older: true}} =
               OperatorMessages.conversation(first_target, limit: 1)

      assert is_binary(cursor)

      assert {:error, {:invalid_cursor, "not-a-cursor"}} =
               OperatorMessages.conversation(first_target, before: "not-a-cursor")

      assert {:error, {:invalid_cursor, ^cursor}} =
               OperatorMessages.conversation(second_target, before: cursor)
    end

    test "a cursor snapshot does not skip an older exchange when a continuation arrives" do
      target = uid("conversation-snapshot")
      actor = %{kind: :operator, id: "operator"}

      oldest = conversation_message!(target, "old question", actor)
      middle = conversation_message!(target, "middle exchange", actor)
      newest = conversation_message!(target, "newest exchange", actor)

      oldest
      |> Ecto.Changeset.change(status: "waiting_for_input", detail: "answer later?")
      |> Repo.update!()

      assert {:ok, %{exchanges: [%{id: newest_id}], before: cursor}} =
               OperatorMessages.conversation(target, limit: 1)

      assert newest_id == newest.provider_correlation_id

      continuation = conversation_message!(target, "late answer", actor)
      assert continuation.provider_correlation_id == oldest.provider_correlation_id

      assert {:ok, %{exchanges: [%{id: middle_id}], before: older_cursor}} =
               OperatorMessages.conversation(target, limit: 1, before: cursor)

      assert middle_id == middle.provider_correlation_id

      assert {:ok,
              %{
                exchanges: [%{id: oldest_id, prompts: [snapshot_prompt]}],
                before: nil,
                has_older: false
              }} =
               OperatorMessages.conversation(target, limit: 1, before: older_cursor)

      assert oldest_id == oldest.provider_correlation_id
      assert snapshot_prompt.text == "old question"
    end
  end

  test "routine removal terminally refuses every undelivered row" do
    target = uid("removed-routine")

    {:ok, queued, :created} =
      OperatorMessages.submit(target, "still queued", [], fn _message -> {:ok, :queued} end)

    {:ok, handed_off, :created} =
      OperatorMessages.submit(target, "accepted but not started", [], fn _message ->
        {:ok, :delivered}
      end)

    {:ok, claimed, :created} =
      OperatorMessages.submit(target, "claim interrupted", [], fn _message -> {:ok, :queued} end)

    {:ok, claimed} = OperatorMessages.claim_delivery(claimed)

    {:ok, completed, :created} =
      OperatorMessages.submit(target, "already completed", [], fn _message ->
        {:ok, :delivered}
      end)

    completed
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    other_target = uid("other-routine")

    {:ok, other, :created} =
      OperatorMessages.submit(other_target, "unrelated", [], fn _message -> {:ok, :queued} end)

    assert :ok = OperatorMessages.settle_removed(target)

    for message <- [queued, handed_off, claimed] do
      settled = OperatorMessages.get(message.message_id)
      assert settled.status == "refused"
      assert settled.delivery == "refused"
      assert settled.error == %{"kind" => "delivery_refused", "detail" => ":routine_removed"}
      assert settled.detail == "routine removed before provider delivery"
      assert settled.claim_token == nil
      assert settled.claimed_at == nil
      assert settled.claim_after_job_id == nil
      assert %DateTime{} = settled.completed_at
      assert {:ok, ^settled, false} = OperatorMessages.await(message.message_id, 0)
    end

    assert OperatorMessages.get(completed.message_id).status == "completed"
    assert OperatorMessages.get(other.message_id).status == "queued"
    assert OperatorMessages.next_queued(target) == nil
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

    assert {:ok, %{exchanges: [exchange], before: nil, has_older: false}} =
             OperatorMessages.conversation(id)

    assert exchange.id == request.provider_correlation_id
    assert exchange.status == "completed"
    assert exchange.detail == "staging or production?"
    assert exchange.answer == "target recorded"

    assert [request_prompt, answer_prompt] = exchange.prompts
    assert request_prompt.text == "choose a target"
    assert request_prompt.detail == "staging or production?"
    assert answer_prompt.text == "staging"
    assert answer_prompt.continued

    # Correlated lifecycle projection updates both durable receipts. The
    # conversation read model owns de-duplication and emits one final answer.
    assert Enum.count(
             Repo.all(OperatorMessage),
             &(&1.target_agent_id == id and &1.result == %{"output" => "target recorded"})
           ) == 2
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

    orphan
    |> Ecto.Changeset.change(status: "executing", delivery: "delivered")
    |> Repo.update!()

    durable
    |> Ecto.Changeset.change(delivery: "started")
    |> Repo.update!()

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

    delete_job_on_exit(job)

    :ok = OperatorMessages.reconcile!()

    assert %{status: "failed", error: %{"kind" => "delivery_interrupted"}} =
             OperatorMessages.get(orphan.message_id)

    assert %{status: "queued", delivery: "started", agent_turn_id: "turn-1"} =
             OperatorMessages.get(durable.message_id)

    job
    |> Ecto.Changeset.change(state: "executing", attempted_at: now)
    |> Repo.update!()

    :ok = OperatorMessages.reconcile!()

    assert %{status: "executing", delivery: "started", started_at: ^now} =
             OperatorMessages.get(durable.message_id)
  end

  test "restart reconciliation preserves messages deferred behind a config handoff" do
    target = uid("handoff-deferred")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "wait for replacement", [], fn _correlation_id ->
               {:deferred, :handoff_pending}
             end)

    assert %{status: "queued", delivery: "queued"} =
             OperatorMessages.get(message.message_id)

    assert :ok = OperatorMessages.reconcile!()

    assert %{status: "queued", delivery: "queued", error: nil} =
             OperatorMessages.get(message.message_id)
  end

  test "an accepted replay is no longer eligible for another replay" do
    target = uid("handoff-accepted")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "deliver once", [], fn _correlation_id ->
               {:deferred, :handoff_pending}
             end)

    assert [queued] = OperatorMessages.queued_for(target)
    assert queued.message_id == message.message_id

    assert {:ok, claimed} = OperatorMessages.claim_delivery(queued)
    assert :ok = OperatorMessages.record_delivery(claimed, :delivered, :claude)
    assert OperatorMessages.queued_for(target) == []
  end

  test "a released admission claim becomes replayable again" do
    target = uid("released-claim")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "retry admission", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, claimed} = OperatorMessages.claim_delivery(message)
    assert claimed.delivery == "admitting"
    assert is_binary(claimed.claim_token)
    assert %DateTime{} = claimed.claimed_at
    assert is_integer(claimed.claim_after_job_id)
    assert OperatorMessages.next_queued(target) == nil
    assert {:error, :not_queued} = OperatorMessages.claim_delivery(message)

    assert :ok = OperatorMessages.release_delivery(claimed)
    assert %{message_id: message_id, delivery: "queued"} = OperatorMessages.next_queued(target)
    assert message_id == message.message_id
    assert {:error, :not_admitting} = OperatorMessages.release_delivery(claimed)

    assert {:ok, reclaimed} = OperatorMessages.claim_delivery(message)
    assert reclaimed.delivery == "admitting"
    assert reclaimed.claim_token != claimed.claim_token
    assert {:error, :not_admitting} = OperatorMessages.release_delivery(claimed)

    assert {:error, :not_admitting} =
             OperatorMessages.record_delivery(claimed, :delivered, :claude)

    assert %{delivery: "admitting", claim_token: token} =
             OperatorMessages.get(message.message_id)

    assert token == reclaimed.claim_token
    assert :ok = OperatorMessages.record_delivery(reclaimed, :delivered, :claude)

    assert %{
             delivery: "delivered",
             claim_token: nil,
             claimed_at: nil,
             claim_after_job_id: nil
           } =
             OperatorMessages.get(message.message_id)
  end

  test "ordered admission only claims the oldest queued message for a target" do
    target = uid("ordered-claim")

    assert {:ok, first, :created} =
             OperatorMessages.submit(target, "first", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, second, :created} =
             OperatorMessages.submit(target, "second", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:error, :not_next} = OperatorMessages.claim_next_delivery(second)
    assert %{delivery: "queued", claim_token: nil} = OperatorMessages.get(second.message_id)

    assert {:ok, claimed} = OperatorMessages.claim_next_delivery(first)
    assert claimed.message_id == first.message_id
    assert claimed.delivery == "admitting"

    assert {:ok, next_claimed} = OperatorMessages.claim_next_delivery(second)
    assert next_claimed.message_id == second.message_id
  end

  test "shared-correlation telemetry leaves the next durable message queued" do
    target = uid("shared-correlation")

    assert {:ok, first, :created} =
             OperatorMessages.submit(target, "ask a question", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, claimed} = OperatorMessages.claim_delivery(first)

    waiting_meta = %{
      agent_id: target,
      correlation_id: first.provider_correlation_id,
      to: :waiting_for_user,
      agent_generation: "generation-1",
      agent_turn_id: "turn-1",
      arc_id: "arc-1"
    }

    assert :ok =
             OperatorMessages.handle_event(
               [:oban_claude, :agent, :transition],
               %{},
               waiting_meta,
               nil
             )

    assert %{status: "waiting_for_input", delivery: "admitting"} =
             OperatorMessages.get(first.message_id)

    assert {:ok, second, :created} =
             OperatorMessages.submit(target, "answer", [], fn _message ->
               {:ok, :queued}
             end)

    assert second.provider_correlation_id == first.provider_correlation_id

    assert %{status: "queued", delivery: "queued"} =
             OperatorMessages.get(second.message_id)

    assert :ok = OperatorMessages.record_delivery(claimed, :delivered, :claude)

    running_meta = %{
      waiting_meta
      | to: :running,
        agent_generation: "generation-2",
        agent_turn_id: "turn-2",
        arc_id: "arc-2"
    }

    assert :ok =
             OperatorMessages.handle_event(
               [:oban_claude, :agent, :transition],
               %{},
               running_meta,
               nil
             )

    assert %{
             status: "executing",
             delivery: "delivered",
             agent_generation: "generation-2",
             agent_turn_id: "turn-2",
             arc_id: "arc-2"
           } = OperatorMessages.get(first.message_id)

    assert %{
             status: "queued",
             delivery: "queued",
             agent_generation: nil,
             agent_turn_id: nil,
             arc_id: nil
           } = OperatorMessages.get(second.message_id)
  end

  test "boot recovery releases a claim newer than a completed shared-correlation job" do
    {first, claimed, job} = claimed_continuation_with_prior_job("completed")

    job =
      job
      |> Ecto.Changeset.change(inserted_at: claimed.claimed_at)
      |> Repo.update!()

    assert DateTime.compare(job.inserted_at, claimed.claimed_at) == :eq
    assert claimed.claim_after_job_id == job.id
    assert :ok = OperatorMessages.reconcile!()

    assert %{status: "failed", delivery: "delivered"} =
             OperatorMessages.get(first.message_id)

    assert %{
             status: "queued",
             delivery: "queued",
             claim_token: nil,
             claimed_at: nil,
             claim_after_job_id: nil,
             agent_generation: nil,
             agent_turn_id: nil,
             arc_id: nil,
             error: nil
           } = OperatorMessages.get(claimed.message_id)

    assert %{message_id: message_id} = OperatorMessages.next_queued(claimed.target_agent_id)
    assert message_id == claimed.message_id
  end

  test "boot recovery releases a claim newer than an active shared-correlation job" do
    {first, claimed, job} = claimed_continuation_with_prior_job("executing")

    assert DateTime.compare(job.inserted_at, claimed.claimed_at) == :lt
    assert claimed.claim_after_job_id == job.id
    assert :ok = OperatorMessages.reconcile!()

    assert %{status: "executing", delivery: "delivered", agent_turn_id: "prior-turn"} =
             OperatorMessages.get(first.message_id)

    assert %{
             status: "queued",
             delivery: "queued",
             claim_token: nil,
             claimed_at: nil,
             claim_after_job_id: nil,
             agent_generation: nil,
             agent_turn_id: nil,
             arc_id: nil,
             started_at: nil
           } = OperatorMessages.get(claimed.message_id)

    assert %{message_id: message_id} = OperatorMessages.next_queued(claimed.target_agent_id)
    assert message_id == claimed.message_id
  end

  test "boot recovery owns a newer provider job even when its timestamp equals the claim" do
    target = uid("equal-claim-time")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "deliver after claim", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, claimed} = OperatorMessages.claim_delivery(message)

    job =
      insert_provider_job(
        claimed.provider_correlation_id,
        "executing",
        claimed.claimed_at
      )

    assert DateTime.compare(job.inserted_at, claimed.claimed_at) == :eq
    assert job.id > claimed.claim_after_job_id
    assert :ok = OperatorMessages.reconcile!()

    assert %{
             status: "executing",
             delivery: "delivered",
             claim_token: nil,
             claimed_at: nil,
             claim_after_job_id: nil,
             agent_turn_id: "prior-turn"
           } = OperatorMessages.get(message.message_id)
  end

  test "boot recovery clears an admitting claim without overwriting terminal lifecycle state" do
    target = uid("terminal-admitting")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "finish during admission", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, claimed} = OperatorMessages.claim_delivery(message)

    _job =
      insert_provider_job(
        claimed.provider_correlation_id,
        "executing",
        claimed.claimed_at
      )

    completed_at = DateTime.utc_now()

    claimed
    |> Ecto.Changeset.change(
      status: "completed",
      result: %{"output" => "finished"},
      completed_at: completed_at
    )
    |> Repo.update!()

    assert :ok = OperatorMessages.reconcile!()

    assert %{
             status: "completed",
             result: %{"output" => "finished"},
             completed_at: ^completed_at,
             delivery: "delivered",
             claim_token: nil,
             claimed_at: nil,
             claim_after_job_id: nil
           } = OperatorMessages.get(message.message_id)
  end

  test "legacy rows without a delivery marker still receive lifecycle telemetry" do
    target = uid("legacy-delivery")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "already admitted", [], fn _message ->
               {:ok, :delivered}
             end)

    message
    |> Ecto.Changeset.change(delivery: nil)
    |> Repo.update!()

    assert :ok =
             OperatorMessages.handle_event(
               [:oban_claude, :agent, :transition],
               %{},
               %{
                 agent_id: target,
                 correlation_id: message.provider_correlation_id,
                 to: :running,
                 agent_generation: "legacy-generation",
                 agent_turn_id: "legacy-turn",
                 arc_id: "legacy-arc"
               },
               nil
             )

    assert %{
             status: "executing",
             delivery: nil,
             agent_generation: "legacy-generation",
             agent_turn_id: "legacy-turn",
             arc_id: "legacy-arc"
           } = OperatorMessages.get(message.message_id)
  end

  test "a fast terminal transition retains the exact admission disposition" do
    target = uid("fast-admission")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "finish immediately", [], fn _message ->
               {:deferred, :handoff_pending}
             end)

    assert {:ok, claimed} = OperatorMessages.claim_delivery(message)

    claimed
    |> Ecto.Changeset.change(status: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert :ok = OperatorMessages.record_delivery(claimed, :started, :claude)

    assert %{status: "completed", delivery: "started", provider: "claude"} =
             OperatorMessages.get(message.message_id)
  end

  test "a deferred caller cannot requeue a row another replay already admitted" do
    target = uid("concurrent-admission")

    assert {:ok, message, :created} =
             OperatorMessages.submit(target, "deliver once", [], fn message ->
               {:ok, claimed} = OperatorMessages.claim_delivery(message)
               :ok = OperatorMessages.record_delivery(claimed, :delivered, :claude)
               {:deferred, :handoff_pending}
             end)

    assert %{status: "queued", delivery: "delivered", provider: "claude"} = message
    assert OperatorMessages.queued_for(target) == []
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

    config =
      id
      |> Custode.Routine.get()
      |> Custode.Routine.agent_config(%{})
      |> Keyword.put(:enqueue_fun, fn args, meta ->
        send(parent, {:provider_enqueued, provider, args, meta})
        {:ok, :queued}
      end)

    {:ok, _pid} = Agents.start_agent(id, config)

    on_exit(fn -> Agents.stop_agent(id, provider) end)
    id
  end

  defp send_message(agent_id, prompt) do
    OperatorMessages.submit(
      agent_id,
      prompt,
      [actor: %{kind: :operator, id: "test-operator"}, via: :mcp],
      fn message ->
        case Agents.cast_prompt(agent_id, prompt, correlation_id: message.provider_correlation_id) do
          :ok -> {:ok, :delivered}
          {:error, reason} -> {:error, reason}
        end
      end
    )
  end

  defp conversation_message!(target, prompt, actor) do
    assert {:ok, message, :created} =
             OperatorMessages.submit(target, prompt, [actor: actor], fn _message ->
               {:ok, :delivered}
             end)

    message
  end

  defp queued_message(target) do
    OperatorMessages.submit(target, "queued", [], fn _correlation_id ->
      {:ok, :delivered}
    end)
  end

  defp claimed_continuation_with_prior_job(state)
       when state in ["completed", "executing"] do
    target = uid("prior-#{state}")

    {:ok, first, :created} =
      OperatorMessages.submit(target, "question", [], fn _message ->
        {:ok, :delivered}
      end)

    first
    |> Ecto.Changeset.change(status: "waiting_for_input")
    |> Repo.update!()

    inserted_at = DateTime.add(DateTime.utc_now(), -60, :second)

    job = insert_provider_job(first.provider_correlation_id, state, inserted_at)

    {:ok, second, :created} =
      OperatorMessages.submit(target, "answer", [], fn _message ->
        {:ok, :queued}
      end)

    {:ok, claimed} = OperatorMessages.claim_delivery(second)
    {first, claimed, job}
  end

  defp insert_provider_job(correlation_id, state, inserted_at)
       when state in ["completed", "executing"] do
    changes =
      case state do
        "completed" ->
          [state: state, inserted_at: inserted_at, completed_at: inserted_at]

        "executing" ->
          [state: state, inserted_at: inserted_at, attempted_at: inserted_at]
      end

    job =
      %{"prompt" => "prior turn"}
      |> Oban.Job.new(
        worker: ObanClaude.Agent.Job,
        queue: :agents,
        meta: %{
          "correlation_id" => correlation_id,
          "agent_generation" => "prior-generation",
          "agent_turn_id" => "prior-turn",
          "arc_id" => "prior-arc"
        }
      )
      |> Ecto.Changeset.change(changes)
      |> Repo.insert!()

    delete_job_on_exit(job)
    job
  end

  defp delete_job_on_exit(job) do
    on_exit(fn ->
      if persisted = Repo.get(Oban.Job, job.id), do: Repo.delete!(persisted)
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
