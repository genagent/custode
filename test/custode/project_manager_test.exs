defmodule Custode.ProjectManagerTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Memory, OperatorMessages, PeerMessageDelivery, PeerMessages, ProjectProgress}

  test "a two-provider plan survives direct operator changes and reconstruction" do
    manager = routine("pm", :claude, :caretaker)
    claude = routine("project-claude", :claude, :assistant)
    codex = routine("project-codex", :codex, :assistant)
    put_env!(:routines, [manager, claude, codex])
    put_env!(:feed_path, nil)
    actor = identity(manager.id)

    for project <- [claude, codex] do
      {:ok, progress} = ProjectProgress.read(actor, project.id)
      assert progress.conversation.exchanges == []
      {:ok, []} = PeerMessages.list(actor)
    end

    requests =
      for project <- [claude, codex] do
        {:ok, message} =
          PeerMessages.send(actor, %{
            recipient: project.id,
            kind: "request",
            subject: "Assess compatibility",
            body: "Report compatibility evidence. Do not change implementation.",
            idempotency_key: uid("pm-request")
          })

        assert :ok = PeerMessageDelivery.deliver(message.id)
        {project, message}
      end

    assert :ok =
             Memory.remember(
               manager.id,
               "plan",
               %{
                 "requests" => Enum.map(requests, fn {_, request} -> request.id end),
                 "next" => "Review compatibility evidence from both owners"
               }
               |> Jason.encode!()
             )

    constraint = String.duplicate("Preserve the existing API. ", 20) <> "Check protocol B only."

    {:ok, operator_message, :created} =
      OperatorMessages.submit(
        claude.id,
        constraint,
        [actor: %{kind: :operator, id: "human"}, via: :liveview],
        fn _message -> {:ok, :queued} end
      )

    {:ok, progress} = ProjectProgress.read(actor, claude.id)
    assert [exchange] = progress.conversation.exchanges
    assert exchange.status == "queued"
    assert [%{id: id, text: ^constraint}] = exchange.prompts
    assert id == operator_message.message_id

    replies =
      for {project, request} <- requests do
        assert {:ok, received} = PeerMessages.read(identity(project.id), request.id)
        assert received.delivery_state == "delivered"
        assert {:ok, _acked} = PeerMessages.acknowledge(identity(project.id), request.id)
        assert {:ok, sent} = PeerMessages.read(actor, request.id)
        assert sent.acknowledged_at
        assert {:ok, [_request]} = PeerMessages.list(actor, correlation_id: request.id)

        {:ok, reply} =
          PeerMessages.reply(identity(project.id), request.id, %{
            subject: "Compatibility evidence",
            body: "Report only: evidence at docs/compatibility.md. No implementation changed.",
            idempotency_key: uid("pm-result")
          })

        assert :ok = PeerMessageDelivery.deliver(reply.id)
        reply
      end

    # Recreate the reader with no transcript/session state. The notebook and
    # request roots, not provider handles, recover the outstanding plan.
    reconstructed_actor = identity(manager.id)
    assert [%{key: "plan", value: plan}] = Memory.recall(manager.id)
    assert length(Jason.decode!(plan)["requests"]) == 2

    for reply <- replies do
      assert {:ok, exchange} =
               PeerMessages.list(reconstructed_actor, correlation_id: reply.correlation_id)

      assert Enum.sort(Enum.map(exchange, & &1.id)) == Enum.sort([reply.reply_to, reply.id])

      assert {:error, :not_found} =
               PeerMessages.read(identity(other_project(reply, claude, codex)), reply.id)
    end

    {:ok, reread} = ProjectProgress.read(reconstructed_actor, claude.id)
    assert hd(hd(reread.conversation.exchanges).prompts).text == constraint
    assert Enum.all?([manager, claude, codex], &(Custode.Gates.open_gates(&1.id) == []))
    assert Enum.all?(Custode.Routine.all(), &(&1.cron == "@yearly"))
  end

  defp routine(prefix, provider, role) do
    %{
      id: uid(prefix),
      provider: provider,
      role: role,
      cron: "@yearly",
      prompt: "Read-only compatibility proof",
      working_dir: tmp_workspace!(),
      workspace: tmp_workspace!(),
      on_note: :ignore
    }
  end

  defp identity(id), do: %{kind: :routine, id: id}
  defp other_project(%{sender: sender}, %{id: sender}, codex), do: codex.id
  defp other_project(_reply, claude, _codex), do: claude.id
end
