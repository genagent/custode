defmodule Custode.OperatorMessagesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Agents, OperatorMessage, OperatorMessages, Repo}
  alias Custode.Operator.Actions

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

  for provider <- [:claude, :codex] do
    @answer_provider provider

    test "#{provider} full structured answers survive durable reads without replacing reports" do
      provider = @answer_provider
      id = start_provider_agent!(provider)

      answer =
        "## Findings\n\n" <>
          String.duplicate("- Full Markdown detail with `code` and café.\n", 600)

      assert String.length(answer) > 16_384

      output = %{
        "directive" => "none",
        "summary" => "Compared the options.",
        "answer" => answer,
        "report" => %{
          "done" => ["Compared two approaches."],
          "verified" => ["Fixture evidence only."]
        }
      }

      assert {:ok, message, :created} = send_message(id, "explain the options fully")
      assert_receive {:provider_enqueued, ^provider, _args, meta}

      response =
        case provider do
          :claude -> ObanClaude.Testing.structured_result(output, session_id: "full-answer")
          :codex -> ObanCodex.Testing.structured_result(output, session_id: "full-answer")
        end

      finish(provider, meta, response)
      assert {:ok, :idle} = Agents.await(id, :idle, 1_000)
      assert {:ok, receipt, false} = OperatorMessages.await(message.message_id, 1_000)
      assert receipt.result == %{"output" => output}

      # These are fresh database reads, as after reconnect, not the provider
      # return value or an in-memory chat projection. The answer stays uncapped.
      assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(id)
      assert exchange.answer == answer
      assert exchange.result["output"]["summary"] == "Compared the options."
      assert {:ok, %{exchanges: [reloaded]}} = Custode.ConversationTimeline.page(id)
      assert reloaded.answer == answer

      reports = Custode.IntervalReports.recent(id)
      assert [%{"summary" => "Compared the options."}] = reports.entries
      refute inspect(reports) =~ "Full Markdown detail"
    end
  end

  for provider <- [:claude, :codex], outcome <- [:success, :failure] do
    @history_provider provider
    @history_outcome outcome

    test "#{provider} retains a full gated answer after continuation #{outcome}" do
      provider = @history_provider
      outcome = @history_outcome
      id = start_provider_agent!(provider)

      answer =
        "## Review\n\n" <> String.duplicate("- Complete `diff` reasoning with café.\n", 600)

      assert String.length(answer) > 16_384

      assert {:ok, request, :created} = send_message(id, "review and prepare the change")
      assert_receive {:provider_enqueued, ^provider, _args, initial_meta}

      finish(provider, initial_meta, approval_answer(provider, answer))

      assert {:ok, {:awaiting_permission, %{id: action_id}}} =
               Agents.await(id, :awaiting_permission, 1_000)

      eventually(fn ->
        assert OperatorMessages.get(request.message_id).status == "waiting_for_approval"
      end)

      assert :processing = Agents.approve_action(id, action_id)
      assert_receive {:provider_enqueued, ^provider, _args, continued_meta}

      eventually(fn ->
        assert OperatorMessages.get(request.message_id).status == "executing"
      end)

      replay_running_transition(provider, id, continued_meta)
      assert {:ok, %{exchanges: [running]}} = OperatorMessages.conversation(id)
      assert running.answer == nil
      assert [%{"answer" => ^answer} = snapshot] = running.prior_answers
      assert is_binary(snapshot["id"])
      assert {:ok, _, _} = DateTime.from_iso8601(snapshot["at"])

      case outcome do
        :success -> finish(provider, continued_meta, result(provider, "Change applied.", "done"))
        :failure -> finish_failed_answer(provider, continued_meta)
      end

      case outcome do
        :success ->
          assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

        :failure ->
          assert {:ok, {:awaiting_permission, _}} = Agents.await(id, :awaiting_permission, 1_000)
      end

      assert {:ok, receipt, false} = OperatorMessages.await(request.message_id, 1_000)
      expected_status = if outcome == :success, do: "completed", else: "failed"
      expected_answer = if outcome == :success, do: "Change applied.", else: nil
      assert receipt.status == expected_status
      assert receipt.result["prior_answers"] == [snapshot]
      assert OperatorMessages.public(receipt).result["prior_answers"] == [snapshot]

      # Re-read both projections after the next turn replaced result.output.
      # Neither the current outcome nor the bounded feed is the answer archive.
      assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(id)
      assert exchange.status == expected_status
      assert exchange.answer == expected_answer
      assert exchange.prior_answers == [snapshot]
      assert {:ok, %{exchanges: [reloaded]}} = Custode.ConversationTimeline.page(id)
      assert reloaded.answer == expected_answer
      assert reloaded.prior_answers == [snapshot]
    end
  end

  test "equal answers from two approval turns retain distinct historical identities" do
    provider = :claude
    id = start_provider_agent!(provider)
    answer = "The **review** is still valid; the next action needs approval."
    assert {:ok, request, :created} = send_message(id, "review both steps")
    assert_receive {:provider_enqueued, :claude, _args, first_meta}

    finish(provider, first_meta, approval_answer(provider, answer))

    assert {:ok, {:awaiting_permission, %{id: first_action}}} =
             Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "waiting_for_approval"
    end)

    assert :processing = Agents.approve_action(id, first_action)
    assert_receive {:provider_enqueued, :claude, _args, second_meta}
    refute first_meta["agent_turn_id"] == second_meta["agent_turn_id"]
    finish(provider, second_meta, approval_answer(provider, answer))

    assert {:ok, {:awaiting_permission, %{id: second_action}}} =
             Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "waiting_for_approval"
    end)

    assert :processing = Agents.approve_action(id, second_action)
    assert_receive {:provider_enqueued, :claude, _args, final_meta}

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "executing"
    end)

    replay_running_transition(provider, id, final_meta)
    finish(provider, final_meta, result(provider, "Both steps are complete.", "done"))
    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)
    assert {:ok, receipt, false} = OperatorMessages.await(request.message_id, 1_000)

    assert [%{"answer" => ^answer} = first, %{"answer" => ^answer} = second] =
             receipt.result["prior_answers"]

    refute first["id"] == second["id"]
    assert {:ok, %{exchanges: [exchange]}} = Custode.ConversationTimeline.page(id)
    assert exchange.prior_answers == [first, second]
    assert exchange.answer == "Both steps are complete."
  end

  test "successive questions retain each answer under the prompt that elicited it" do
    id = start_provider_agent!(:claude)
    first_answer = "Staging limits the blast radius; production serves real traffic."
    second_answer = "Staging is selected. A dry run can verify the change before applying it."

    assert {:ok, request, :created} = send_message(id, "compare the deployment targets")
    assert_receive {:provider_enqueued, :claude, _args, first_meta}

    finish(
      :claude,
      first_meta,
      ObanClaude.Testing.structured_result(
        %{
          "directive" => "ask_user",
          "question" => "Which target?",
          "summary" => "Compared deployment targets.",
          "answer" => first_answer
        },
        session_id: "first-question"
      )
    )

    assert {:ok, {:waiting_for_user, "Which target?"}} =
             Agents.await(id, :waiting_for_user, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "waiting_for_input"
    end)

    assert {:ok, first_reply, :created} = send_message(id, "staging")
    assert first_reply.continues_message_id == request.message_id
    assert_receive {:provider_enqueued, :claude, _args, second_meta}

    finish(
      :claude,
      second_meta,
      ObanClaude.Testing.structured_result(
        %{
          "directive" => "ask_user",
          "question" => "Dry run or apply?",
          "summary" => "Prepared the staging change.",
          "answer" => second_answer
        },
        session_id: "second-question"
      )
    )

    assert {:ok, {:waiting_for_user, "Dry run or apply?"}} =
             Agents.await(id, :waiting_for_user, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(first_reply.message_id).status == "waiting_for_input"
    end)

    assert {:ok, second_reply, :created} = send_message(id, "dry run")
    assert second_reply.continues_message_id == first_reply.message_id
    assert_receive {:provider_enqueued, :claude, _args, final_meta}

    finish(:claude, final_meta, result(:claude, "Dry run completed.", "questions-complete"))
    assert {:ok, :idle} = Agents.await(id, :idle, 1_000)

    assert {:ok, %{status: "completed"}, false} =
             OperatorMessages.await(second_reply.message_id, 1_000)

    first_message_id = request.message_id
    second_message_id = first_reply.message_id
    assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(id)

    assert [
             %{"answer" => ^first_answer, "message_id" => ^first_message_id},
             %{"answer" => ^second_answer, "message_id" => ^second_message_id}
           ] = exchange.prior_answers

    assert exchange.answer == "Dry run completed."
    assert {:ok, %{exchanges: [reloaded]}} = Custode.ConversationTimeline.page(id)
    assert reloaded.prior_answers == exchange.prior_answers
  end

  test "rejecting an action preserves the answer delivered with its approval request" do
    id = start_provider_agent!(:claude)
    answer = "The **review** found the change ready, subject to your approval."
    assert {:ok, request, :created} = send_message(id, "review the proposed change")
    assert_receive {:provider_enqueued, :claude, _args, meta}
    finish(:claude, meta, approval_answer(:claude, answer))

    assert {:ok, {:awaiting_permission, %{id: action_id}}} =
             Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert OperatorMessages.get(request.message_id).status == "waiting_for_approval"
    end)

    assert :ok =
             Actions.reject(id, action_id, "Do not apply this change", standing: false)

    assert {:ok, receipt, false} = OperatorMessages.await(request.message_id, 1_000)
    assert receipt.status == "refused"
    assert receipt.result["output"] == nil
    assert [%{"answer" => ^answer} = snapshot] = receipt.result["prior_answers"]
    assert snapshot["message_id"] == request.message_id

    assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(id)
    assert exchange.status == "refused"
    assert exchange.answer == nil
    assert exchange.error == "Do not apply this change"
    assert exchange.prior_answers == [snapshot]
    assert {:ok, %{exchanges: [reloaded]}} = Custode.ConversationTimeline.page(id)
    assert reloaded.prior_answers == [snapshot]
  end

  test "routine removal retains answers already delivered before a pending question or approval" do
    for status <- ["waiting_for_input", "waiting_for_approval"] do
      target = uid("removed-answer")
      answer = "The investigation is complete; the next step needs your input."
      actor = %{kind: :operator, id: uid("removal-operator")}
      message = conversation_message!(target, "investigate the options", actor)

      message
      |> Ecto.Changeset.change(
        status: status,
        agent_generation: "removed-generation",
        agent_turn_id: "removed-turn",
        result: %{"output" => %{"answer" => answer, "summary" => "Investigation complete."}}
      )
      |> Repo.update!()

      assert :ok = OperatorMessages.settle_removed(target)
      assert {:ok, receipt, false} = OperatorMessages.await(message.message_id, 0)
      assert receipt.status == "refused"
      assert receipt.result["output"] == nil
      assert [%{"answer" => ^answer} = snapshot] = receipt.result["prior_answers"]
      assert snapshot["message_id"] == message.message_id
      assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(target)
      assert exchange.answer == nil
      assert exchange.prior_answers == [snapshot]
    end
  end

  test "history distinguishes explicit answers, legacy prose and report-only output" do
    cases = [
      {%{
         "answer" => "Full answer",
         "summary" => "Brief",
         "directive" => "ask_user",
         "question" => "Which?"
       }, "Full answer"},
      {%{"answer" => nil, "summary" => "Quiet sweep", "report" => %{"done" => ["Checked."]}},
       nil},
      {%{"answer" => " \n", "summary" => "Quiet sweep"}, nil},
      {%{"report" => %{"done" => ["Legacy report without prose."]}}, nil},
      {%{"directive" => "ask_user", "question" => "Which?", "summary" => "Waiting"}, "Which?"},
      {%{"directive" => "request_permission", "action" => "Publish?", "summary" => "Ready"},
       "Publish?"},
      {%{"summary" => "Legacy answer"}, "Legacy answer"},
      {"Plain **Markdown** answer", "Plain **Markdown** answer"}
    ]

    for {output, expected} <- cases do
      target = uid("answer-history")

      message =
        conversation_message!(target, "question", %{kind: :operator, id: "history-reader"})

      message
      |> Ecto.Changeset.change(status: "completed", result: %{"output" => output})
      |> Repo.update!()

      assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(target)
      assert exchange.answer == expected
      assert exchange.result == %{"output" => output}
    end
  end

  test "failed and refused receipts never promote a structured answer to successful prose" do
    for status <- ["failed", "refused"] do
      target = uid("unsuccessful-answer")

      message =
        conversation_message!(target, "do the work", %{kind: :operator, id: "failure-reader"})

      message
      |> Ecto.Changeset.change(
        status: status,
        result: %{"output" => %{"answer" => "Proposed outcome", "summary" => "Tentative report"}},
        error: %{"detail" => "Execution did not succeed"}
      )
      |> Repo.update!()

      assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(target)
      assert exchange.answer == nil
      assert exchange.error == "Execution did not succeed"
      assert exchange.result["output"]["answer"] == "Proposed outcome"
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
        %{
          "directive" => "ask_user",
          "question" => "staging or production?",
          "summary" => "Waiting for target selection.",
          "answer" => "Staging limits the blast radius; production serves real traffic."
        },
        session_id: "question-session"
      )
    )

    assert {:ok, {:waiting_for_user, "staging or production?"}} =
             Agents.await(id, :waiting_for_user, 1_000)

    eventually(fn ->
      assert %{status: "waiting_for_input", detail: "staging or production?"} =
               OperatorMessages.get(request.message_id)
    end)

    assert {:ok, %{exchanges: [waiting]}} = OperatorMessages.conversation(id)
    assert waiting.status == "waiting_for_input"
    assert waiting.answer == "Staging limits the blast radius; production serves real traffic."
    assert waiting.detail == "staging or production?"

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

    assert [%{"answer" => "Staging limits the blast radius; production serves real traffic."}] =
             exchange.prior_answers

    assert [request_prompt, answer_prompt] = exchange.prompts
    assert request_prompt.text == "choose a target"
    assert request_prompt.detail == "staging or production?"
    assert answer_prompt.text == "staging"
    assert answer_prompt.continued

    # Correlated lifecycle projection updates both durable receipts. The
    # conversation read model owns de-duplication and emits one final answer.
    assert Enum.count(
             Repo.all(OperatorMessage),
             &(&1.target_agent_id == id and &1.result["output"] == "target recorded")
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
        %{
          "directive" => "request_permission",
          "action" => "merge the change",
          "summary" => "Ready for review.",
          "answer" => "The change is ready; merging still requires your approval."
        },
        session_id: "gate-session"
      )
    )

    assert {:ok, {:awaiting_permission, %{id: action_id}}} =
             Agents.await(id, :awaiting_permission, 1_000)

    eventually(fn ->
      assert %{status: "waiting_for_approval", detail: "merge the change"} =
               OperatorMessages.get(request.message_id)
    end)

    assert {:ok, %{exchanges: [waiting]}} = OperatorMessages.conversation(id)
    assert waiting.status == "waiting_for_approval"
    assert waiting.answer == "The change is ready; merging still requires your approval."
    assert waiting.detail == "merge the change"

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

  test "failed Codex telemetry preserves safe stdout diagnostics on the exact receipt" do
    target = uid("codex-diagnostic")
    actor = %{kind: :operator, id: uid("diagnostic-operator")}

    {:ok, request, :created} =
      OperatorMessages.submit(target, "inspect model compatibility", [actor: actor], fn _ ->
        {:ok, :delivered}
      end)

    {:ok, queued, :created} =
      OperatorMessages.submit(target, "keep this separate request queued", [actor: actor], fn _ ->
        {:ok, :queued}
      end)

    stdout =
      [
        %{"type" => "thread.started", "thread_id" => "diagnostic-thread"},
        %{"type" => "item.completed", "item" => %{"text" => "Error: PRIVATE_MODEL_OUTPUT"}},
        %{"type" => "config", "message" => "PRIVATE_CONFIG_OUTPUT"},
        %{
          "type" => "turn.failed",
          "error" => %{
            "message" =>
              "Selected model is unsupported. Authorization: Bearer PRIVATE_BEARER_SENTINEL"
          }
        }
      ]
      |> Enum.map_join("\n", &Jason.encode!/1)

    result = CodexWrapper.Result.from_cmd({stdout, 2})

    assert {{:error, {:command_failed, 2}}, ^result} =
             failed_codex_run(request, result)

    receipt = OperatorMessages.get(request.message_id)
    assert receipt.status == "failed"
    assert receipt.error["kind"] == "provider_result_error"
    assert receipt.error["detail"] =~ "exit 2: Selected model is unsupported"
    refute receipt.error["detail"] == inspect("")
    assert receipt.result == %{"output" => nil}
    assert OperatorMessages.get(queued.message_id) == queued

    assert {:ok, conversation} = OperatorMessages.conversation(target)
    exchange = Enum.find(conversation.exchanges, &(&1.id == request.provider_correlation_id))
    assert exchange.answer == nil
    assert exchange.error == receipt.error["detail"]

    assert [failure] = Custode.Feed.recent_by_event("turn_failed", agent: target)
    assert failure["detail"] == receipt.error["detail"]
    assert failure["kind"] == "command_failed"
    assert failure["category"] == "unknown_harness_error"
    assert failure["retryable"]

    public = Jason.encode!(%{conversation: conversation, feed: failure, result: receipt.result})

    for secret <- ["PRIVATE_MODEL_OUTPUT", "PRIVATE_CONFIG_OUTPUT", "PRIVATE_BEARER_SENTINEL"] do
      refute public =~ secret
    end
  end

  test "a failed Codex continuation cannot revive an earlier answer or render nil as an answer" do
    target = uid("codex-failed-continuation")
    actor = %{kind: :operator, id: uid("continuation-operator")}

    {:ok, original, :created} =
      OperatorMessages.submit(target, "inspect the environment", [actor: actor], fn _ ->
        {:ok, :delivered}
      end)

    original
    |> Ecto.Changeset.change(
      status: "waiting_for_input",
      result: %{"output" => "EARLIER_ANSWER_MUST_NOT_RETURN"}
    )
    |> Repo.update!()

    {:ok, continuation, :created} =
      OperatorMessages.submit(target, "staging only", [actor: actor], fn _ ->
        {:ok, :delivered}
      end)

    assert continuation.provider_correlation_id == original.provider_correlation_id

    # A settled earlier row remains in the exchange, but is outside the
    # failure update's active-row predicate.
    OperatorMessages.get(original.message_id)
    |> Ecto.Changeset.change(status: "completed")
    |> Repo.update!()

    result = CodexWrapper.Result.from_cmd({"Error: model access unavailable", 1})
    assert {{:error, {:command_failed, 1}}, ^result} = failed_codex_run(continuation, result)

    assert OperatorMessages.get(original.message_id).result ==
             %{"output" => "EARLIER_ANSWER_MUST_NOT_RETURN"}

    assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(target)
    assert exchange.status == "failed"
    assert exchange.answer == nil
    assert exchange.result == %{"output" => nil}
    assert exchange.error == "exit 1: Error: model access unavailable"
    assert Enum.map(exchange.prompts, & &1.id) == [original.message_id, continuation.message_id]
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

  test "restart recovery preserves a gated answer before adopting a newer available job" do
    target = uid("recovered-answer")
    actor = %{kind: :operator, id: uid("recovery-operator")}
    answer = "The staging checks passed; choose whether to continue."
    request = conversation_message!(target, "check staging", actor)

    request
    |> Ecto.Changeset.change(
      status: "waiting_for_input",
      agent_generation: "prior-generation",
      agent_turn_id: "prior-turn",
      result: %{"output" => %{"answer" => answer, "summary" => "Staging checks passed."}}
    )
    |> Repo.update!()

    continuation = conversation_message!(target, "continue", actor)
    assert continuation.provider_correlation_id == request.provider_correlation_id

    meta = %{
      "agent_id" => target,
      "correlation_id" => request.provider_correlation_id,
      "agent_generation" => "recovered-generation",
      "agent_turn_id" => "recovered-turn",
      "arc_id" => "recovered-arc"
    }

    job =
      %{"prompt" => "continue"}
      |> Oban.Job.new(worker: ObanClaude.Agent.Job, queue: :agents, meta: meta)
      |> Repo.insert!()

    delete_job_on_exit(job)
    assert job.state == "available"
    assert :ok = OperatorMessages.reconcile!()

    recovered = OperatorMessages.get(request.message_id)
    assert recovered.status == "queued"
    assert recovered.agent_turn_id == "recovered-turn"
    assert recovered.result["output"] == nil
    assert [%{"answer" => ^answer} = snapshot] = recovered.result["prior_answers"]
    assert snapshot["message_id"] == request.message_id

    replay_running_transition(:claude, target, meta)
    failure = ObanClaude.Testing.result(result: "Continuation failed", is_error: true)

    assert :ok =
             OperatorMessages.handle_event(
               [:oban_claude, :run, :stop],
               %{duration: 1},
               %{result: failure, args: %{}, job: %{meta: meta}},
               nil
             )

    assert {:ok, %{exchanges: [exchange]}} = OperatorMessages.conversation(target)
    assert exchange.status == "failed"
    assert exchange.answer == nil
    assert exchange.prior_answers == [snapshot]
    assert {:ok, %{exchanges: [reloaded]}} = Custode.ConversationTimeline.page(target)
    assert reloaded.prior_answers == [snapshot]
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

  defp failed_codex_run(message, result) do
    ObanCodex.run(%{"prompt" => "fixture only"},
      job: %Oban.Job{
        meta: %{
          "agent_id" => message.target_agent_id,
          "correlation_id" => message.provider_correlation_id,
          "agent_generation" => "diagnostic-generation",
          "agent_turn_id" => "diagnostic-turn"
        }
      },
      query_fun: ObanCodex.Testing.respond(result)
    )
  end

  defp approval_answer(provider, answer) do
    output = %{
      "directive" => "request_permission",
      "action" => "Apply the reviewed change",
      "summary" => "Review complete; awaiting approval.",
      "answer" => answer
    }

    case provider do
      :claude -> ObanClaude.Testing.structured_result(output, session_id: "approval")
      :codex -> ObanCodex.Testing.structured_result(output, session_id: "approval")
    end
  end

  defp replay_running_transition(provider, id, meta) do
    assert :ok =
             OperatorMessages.handle_event(
               [telemetry_provider(provider), :agent, :transition],
               %{},
               %{
                 agent_id: id,
                 correlation_id: meta["correlation_id"],
                 to: :running,
                 agent_generation: meta["agent_generation"],
                 agent_turn_id: meta["agent_turn_id"],
                 arc_id: meta["arc_id"]
               },
               nil
             )
  end

  defp finish_failed_answer(provider, meta) do
    failed =
      case provider do
        :claude ->
          ObanClaude.Testing.structured_result(
            %{"answer" => "Unconfirmed result", "summary" => "Not completed"},
            is_error: true,
            result: "Error: provider stopped before completion"
          )

        :codex ->
          ObanCodex.Testing.failed_result("Error: provider stopped before completion")
      end

    :telemetry.execute(
      [telemetry_provider(provider), :run, :stop],
      %{duration: 1, cost_usd: 0.0},
      %{result: failed, args: %{}, job: %{meta: meta}}
    )

    job = %Oban.Job{meta: meta, attempt: 1, max_attempts: 1}

    case provider do
      :claude -> ObanClaude.Agent.Job.handle_error({:error, :result_error}, failed, job)
      :codex -> ObanCodex.Agent.Job.handle_error({:error, {:command_failed, 1}}, failed, job)
    end
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
