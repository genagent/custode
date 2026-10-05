defmodule Custode.MissionsProtocolContractTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Memory,
    Notebook,
    OperatorMessages,
    PeerMessage,
    PeerMessages,
    ProjectProgress,
    Repo
  }

  setup do
    manager = routine("mission-manager", :claude, :caretaker)
    producer = routine("mission-inventory", :claude, :assistant)
    checker = routine("mission-check", :codex, :assistant)
    ids = Enum.map([manager, producer, checker], & &1.id)
    put_env!(:routines, [manager, producer, checker])
    put_env!(:feed_path, nil)
    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false

    on_exit(fn ->
      messages =
        Repo.all(
          from(m in PeerMessage, where: m.sender in ^ids or m.recipient in ^ids, select: m.id)
        )

      Repo.delete_all(
        from(j in Oban.Job,
          where:
            j.worker == "Custode.PeerMessageJob" and
              fragment("json_extract(?, '$.message_id')", j.args) in ^messages
        )
      )

      Repo.delete_all(from(m in PeerMessage, where: m.id in ^messages))
      Repo.delete_all(from(m in Memory.Entry, where: m.agent_id in ^ids))
      Repo.delete_all(from(j in Notebook.JournalEntry, where: j.routine_id in ^ids))
      Repo.delete_all(from(t in Notebook.Todo, where: t.routine_id in ^ids))
      Repo.delete_all(from(m in Custode.OperatorMessage, where: m.target_agent_id in ^ids))
      Repo.delete_all(from(f in Custode.Feed.Entry, where: f.agent in ^ids))
      Repo.delete_all(from(s in Custode.AgentAuthorizationSnapshot, where: s.routine_id in ^ids))
    end)

    %{manager: manager, producer: producer, checker: checker, objective: uid("mission-objective")}
  end

  test "one routine pins the same changed constraint and artifact without peer coordination",
       ctx do
    baseline = %{"objective" => ctx.objective, "criteria" => initial_criteria(), "revision" => 1}
    persist(ctx.producer.id, ctx.objective, baseline)

    {:ok, inventory} =
      Notebook.todo_add(
        ctx.producer.id,
        "Inventory objective " <> ctx.objective <> ": read its current memory record"
      )

    {:ok, check} =
      Notebook.todo_add(
        ctx.producer.id,
        "Check objective " <> ctx.objective <> ": read its current memory record"
      )

    assert Enum.map(Notebook.todos(ctx.producer.id), & &1.id) == [inventory.id, check.id]

    {:ok, operator, :created} =
      OperatorMessages.submit(
        ctx.producer.id,
        constraint(),
        [actor: %{kind: :operator, id: "fixture-human"}, via: :liveview],
        fn _message -> {:ok, :queued} end
      )

    {:ok, progress} = ProjectProgress.read(identity(ctx.manager), ctx.producer.id)

    assert Enum.any?(progress.conversation.exchanges, fn exchange ->
             Enum.any?(
               exchange.prompts,
               &(&1.id == operator.message_id and &1.text == constraint())
             )
           end)

    current =
      Map.merge(baseline, %{
        "revision" => 2,
        "criteria" => criteria(),
        "constraint" => constraint(),
        "operator_message" => operator.message_id,
        "artifact" => artifact(),
        "acceptance" => "not established"
      })

    persist(ctx.producer.id, ctx.objective, current)
    assert recall(ctx.producer.id, ctx.objective) == current
    {:ok, _} = Notebook.todo_complete(inventory.id)
    assert [remaining] = Notebook.todos(ctx.producer.id)
    assert remaining.id == check.id
    {:ok, _} = Notebook.todo_complete(check.id)
    assert length(Notebook.todos(ctx.producer.id, "done")) == 2
    assert {:ok, []} = PeerMessages.list(identity(ctx.producer))
    # Host-authored fixture bookkeeping, not equivalent completed native tasks.
  end

  test "dependent peer convention reconstructs send gap, direct change and blocked handoff",
       ctx do
    manager = identity(ctx.manager)
    request = request(ctx.producer.id, ctx.objective, "inventory", initial_criteria())

    plan = %{
      "objective" => ctx.objective,
      "criteria" => initial_criteria(),
      "revision" => 1,
      "inventory_request" => request,
      "inventory_message" => nil,
      "check_message" => nil
    }

    persist(ctx.manager.id, ctx.objective, plan)
    {:ok, _} = Notebook.journal_append(ctx.manager.id, Jason.encode!(plan), title: ctx.objective)
    parent = self()

    # Loss after the durable send commits, before the separate memory link update.
    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, sent} = PeerMessages.send(manager, request)
        send(parent, {:persisted_request, sent.id})
        exit(:fixture_coordinator_loss)
      end)

    assert_receive {:persisted_request, original_id}
    assert_receive {:DOWN, ^monitor, :process, ^pid, :fixture_coordinator_loss}
    recovered = recall(ctx.manager.id, ctx.objective)
    assert recovered["inventory_message"] == nil

    assert {:ok, original} =
             PeerMessages.send(identity(ctx.manager), recovered["inventory_request"])

    assert original.id == original_id
    assert {:ok, [only]} = PeerMessages.list(manager, direction: :sent)
    assert only.id == original_id
    recovered = Map.put(recovered, "inventory_message", original_id)
    persist(ctx.manager.id, ctx.objective, recovered)

    {:ok, check_request} =
      PeerMessages.send(
        manager,
        request(
          ctx.checker.id,
          ctx.objective,
          "check",
          "Wait for a pinned inventory; " <> criteria()
        )
      )

    {:ok, blocked} =
      PeerMessages.reply(
        identity(ctx.checker),
        check_request.id,
        reply(ctx.objective, "blocked", %{"status" => "blocked", "dependency" => original_id})
      )

    assert blocked.correlation_id == check_request.id
    assert blocked.acknowledged_at == nil
    assert Jason.decode!(blocked.body)["status"] == "blocked"

    constraint = "Include caller scope as a separate field; retain the same read-only authority."

    {:ok, operator, :created} =
      OperatorMessages.submit(
        ctx.producer.id,
        constraint,
        [actor: %{kind: :operator, id: "fixture-human"}, via: :liveview],
        fn _message -> {:ok, :queued} end
      )

    {:ok, progress} = ProjectProgress.read(manager, ctx.producer.id)

    assert Enum.any?(progress.conversation.exchanges, fn exchange ->
             Enum.any?(
               exchange.prompts,
               &(&1.id == operator.message_id and &1.text == constraint)
             )
           end)

    changed_body = %{
      "objective" => ctx.objective,
      "revision" => 2,
      "supersedes" => original_id,
      "operator_message" => operator.message_id,
      "constraint" => constraint,
      "criteria" => criteria()
    }

    assert {:error, :idempotency_conflict} =
             PeerMessages.send(manager, Map.put(request, "body", Jason.encode!(changed_body)))

    {:ok, revised_request} =
      PeerMessages.send(manager, %{
        "recipient" => ctx.producer.id,
        "kind" => "fyi",
        "subject" => "Inventory constraint revision2",
        "body" => Jason.encode!(changed_body),
        "idempotency_key" => ctx.objective <> "-inventory-v2"
      })

    assert revised_request.correlation_id == revised_request.id
    assert revised_request.id != original_id
    {:ok, delivered_revision} = PeerMessages.read(identity(ctx.producer), revised_request.id)
    revised_body = Jason.decode!(delivered_revision.body)
    assert revised_body["operator_message"] == operator.message_id
    assert revised_body["constraint"] == constraint
    assert revised_body["criteria"] == criteria()
    assert {:ok, retained_original} = PeerMessages.read(manager, original_id)
    assert retained_original.body == request["body"]
    assert retained_original.delivery_state == "pending"

    artifact = artifact()

    {:ok, produced} =
      PeerMessages.reply(
        identity(ctx.producer),
        revised_request.id,
        reply(ctx.objective, "inventory-result", %{
          "status" => "reported",
          "artifact" => artifact,
          "operator_message" => operator.message_id
        })
      )

    # Follow up to the received blocked reply, not our own outgoing request.
    {:ok, handoff} =
      PeerMessages.reply(
        manager,
        blocked.id,
        reply(ctx.objective, "handoff", %{
          "artifact" => artifact,
          "producer_reply" => produced.id,
          "operator_message" => operator.message_id
        })
      )

    assert handoff.correlation_id == check_request.id
    {:ok, received_handoff} = PeerMessages.read(identity(ctx.checker), handoff.id)
    handoff_body = Jason.decode!(received_handoff.body)
    assert handoff_body["artifact"] == artifact
    assert handoff_body["operator_message"] == operator.message_id

    {:ok, checked} =
      PeerMessages.reply(
        identity(ctx.checker),
        handoff.id,
        reply(ctx.objective, "check-result", %{"status" => "reported", "artifact" => artifact})
      )

    final =
      Map.merge(recovered, %{
        "revision" => 2,
        "criteria" => criteria(),
        "constraint" => constraint,
        "operator_message" => operator.message_id,
        "inventory_message" => revised_request.id,
        "inventory_reply" => produced.id,
        "check_message" => check_request.id,
        "check_reply" => checked.id,
        "artifact" => artifact,
        "status" => "reported",
        "acceptance" => "not established"
      })

    persist(ctx.manager.id, ctx.objective, final)
    {:ok, _} = Notebook.journal_append(ctx.manager.id, Jason.encode!(final), title: ctx.objective)
    fresh = identity(ctx.manager)
    restored = recall(ctx.manager.id, ctx.objective)
    assert restored == final
    {:ok, chain} = PeerMessages.list(fresh, correlation_id: restored["check_message"])

    assert MapSet.new(Enum.map(chain, & &1.id)) ==
             MapSet.new([check_request.id, blocked.id, handoff.id, checked.id])

    assert Jason.decode!(Enum.find(chain, &(&1.id == checked.id)).body)["artifact"] == artifact
    assert {:ok, all_mail} = PeerMessages.list(fresh)
    assert length(all_mail) == 7
    assert length(Notebook.journal(ctx.manager.id, 100, search: ctx.objective)) == 2
    assert {:error, :not_found} = PeerMessages.read(identity(ctx.producer), checked.id)

    assert Enum.all?(
             [ctx.manager, ctx.producer, ctx.checker],
             &(Custode.Gates.open_gates(&1.id) == [])
           )
  end

  defp initial_criteria,
    do: "Inventory fields name/schema; check both against the same pinned artifact."

  defp constraint,
    do: "Include caller scope as a separate field; retain the same read-only authority."

  defp artifact,
    do: %{
      "revision" => "fixture-inventory-v2",
      "sha256" => digest("fixture inventory with caller scope")
    }

  defp criteria,
    do: "Inventory fields name/schema/caller; check all three against the same pinned artifact."

  defp identity(routine), do: %{kind: :routine, id: routine.id}
  defp persist(owner, key, value), do: Memory.remember(owner, key, Jason.encode!(value))

  defp recall(owner, key) do
    {:ok, value} = Memory.recall(owner, key)
    Jason.decode!(value)
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp request(recipient, objective, assignment, instruction),
    do: %{
      "recipient" => recipient,
      "kind" => "request",
      "subject" => "Bounded " <> assignment,
      "body" =>
        Jason.encode!(%{
          "objective" => objective,
          "assignment" => assignment,
          "instruction" => instruction
        }),
      "idempotency_key" => objective <> "-" <> assignment
    }

  defp reply(objective, suffix, body),
    do: %{
      subject: "Bounded fixture report",
      body: Jason.encode!(body),
      idempotency_key: objective <> "-" <> suffix
    }

  defp routine(prefix, provider, role),
    do: %{
      id: uid(prefix),
      provider: provider,
      role: role,
      cron: :manual,
      prompt: "Nonpaid protocol fixture only",
      workspace: tmp_workspace!(),
      working_dir: tmp_workspace!(),
      on_note: :ignore
    }
end
