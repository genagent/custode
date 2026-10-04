defmodule Custode.CurrentRunTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.{CurrentRun, HelperRecords, OperatorMessage, OperatorMessages, Repo, SubAgents}
  alias Custode.MCP.CallContext
  alias Custode.MCP.CurrentRunTools.Read
  alias Custode.MCP.Tools

  @operator %{kind: :operator, id: "current-run-operator"}

  setup do
    parent = uid("current-parent")
    manager = uid("current-manager")
    child = uid("current-child")

    put_env!(:routines, [
      %{
        id: parent,
        role: :backlog_worker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "work"
      },
      %{
        id: manager,
        role: :caretaker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "coordinate"
      }
    ])

    on_exit(fn ->
      Repo.delete_all(from(m in OperatorMessage, where: m.target_agent_id in ^[parent, child]))
      Repo.delete_all(from(r in SubAgents.Row, where: r.agent_id == ^child))
      Repo.delete_all(from(r in HelperRecords.Row, where: r.parent in ^[parent, manager]))
      Repo.delete_all(from(f in Custode.Feed.Entry, where: f.agent == ^child))
    end)

    %{parent: parent, manager: manager, child: child}
  end

  test "all pending counts are independent of the bounded receipt page and delivery stage", ctx do
    rows = for n <- 1..28, do: message!(ctx.parent, "instruction #{n}")
    [admitting, executing, waiting | _rest] = rows
    assert {:ok, claimed} = OperatorMessages.claim_delivery(admitting)
    update!(executing, status: "executing", delivery: "delivered")
    update!(waiting, status: "waiting_for_input", delivery: "delivered")
    message!(ctx.parent, "private delegation", %{kind: :routine, id: ctx.manager})

    assert {:ok, facts} = CurrentRun.read(@operator, ctx.parent)
    assert facts.schema_version == "custode.current_run.v1"
    assert facts.input.queued == 25
    assert facts.input.admitting == 1
    assert facts.input.executing == 1
    assert facts.input.waiting_for_input == 1
    assert length(facts.input.receipts) == 20
    assert facts.input.has_more_receipts
    assert facts.consistency == "independent_observations"
    assert facts.plan.availability == "no_identified_document"
    refute Jason.encode!(facts) =~ claimed.claim_token
    refute Jason.encode!(facts) =~ "private delegation"
    assert {:ok, fresh} = CurrentRun.read(@operator, ctx.parent)
    assert fresh.input == facts.input |> Map.put(:observed_at, fresh.input.observed_at)
    assert :offline = Custode.Agents.live_provider(ctx.parent)
  end

  test "removed helper results survive cleanup without restoring ownership or leaking bodies",
       ctx do
    assert :ok = SubAgents.record_spawn!(ctx.child, ctx.parent, %{workspace: "/tmp/helper"})
    message = message!(ctx.child, "private brief", %{kind: :routine, id: ctx.parent})
    Custode.Feed.record(%{agent: ctx.child, event: "turn", summary: "Initial helper evidence."})
    SubAgents.forget(ctx.child)
    update!(message, status: "completed", result: %{"output" => "retained private result"})
    assert SubAgents.get(ctx.child) == nil

    assert {:ok, facts} = CurrentRun.read(@operator, ctx.parent)
    assert [helper] = facts.helpers.entries
    assert helper.registry_state == "removed"
    assert helper.settlement == "not_observed"
    assert [%{summary: "Initial helper evidence."}] = helper.reports
    assert [receipt] = helper.receipts
    assert receipt.message_id == message.message_id
    assert receipt.result_preview == "retained private result"
    assert receipt.result_reference.arguments.message_id == message.message_id
    assert helper.owner_link =~ ctx.parent
    assert {:ok, restricted} = CurrentRun.read(%{kind: :routine, id: ctx.manager}, ctx.parent)
    assert [%{receipts: [%{result_preview: nil}]}] = restricted.helpers.entries
    refute Jason.encode!(restricted) =~ "retained private result"
    refute Jason.encode!(facts) =~ "private brief"
    refute Jason.encode!(facts) =~ message.idempotency_key
    frame = %CallContext{assigns: %{custode_identity: %{kind: :routine, id: ctx.parent}}}
    assert {:error, _reason} = Tools.check_delegated_target(frame, ctx.child, :manage)
  end

  test "reusing a helper id retains both owners without mixing later receipts", ctx do
    SubAgents.record_spawn!(ctx.child, ctx.parent, %{workspace: "/tmp/helper"})
    first = message!(ctx.child, "first brief", %{kind: :routine, id: ctx.parent})
    SubAgents.forget(ctx.child)
    SubAgents.record_spawn!(ctx.child, ctx.manager, %{workspace: "/tmp/other"})
    second = message!(ctx.child, "second brief", %{kind: :routine, id: ctx.manager})
    update!(first, status: "completed", result: %{"output" => "late first answer"})
    assert {:ok, old} = CurrentRun.read(@operator, ctx.parent)
    assert [%{receipts: [%{message_id: id}]}] = old.helpers.entries
    assert id == first.message_id
    assert {:ok, new} = CurrentRun.read(@operator, ctx.manager)
    assert [%{receipts: [%{message_id: id}]}] = new.helpers.entries
    assert id == second.message_id
    assert SubAgents.get(ctx.child).parent == ctx.manager
  end

  test "MCP refuses forged readers and shares facts with project progress", ctx do
    assert {:ok, facts} = CurrentRun.read(@operator, ctx.parent)
    assert {:ok, progress} = Custode.ProjectProgress.read(@operator, ctx.parent)
    assert progress.current_run.schema_version == facts.schema_version
    assert progress.current_run.execution.facts == facts.execution.facts

    for actor <- [
          nil,
          %{},
          %{kind: :routine, id: ctx.parent},
          %{kind: :sub_agent, id: ctx.manager}
        ] do
      assert {:error, _reason} = CurrentRun.read(actor, ctx.parent)
      assert {:error, _reason} = CurrentRun.read(actor, "unknown")
    end

    frame = %CallContext{assigns: %{custode_identity: @operator}}

    wire =
      Read.execute(%{routine_id: ctx.parent}, frame) |> tool_json()

    assert wire["schema_version"] == facts.schema_version
    assert wire["input"]["queued"] == 0

    assert Read.execute(%{routine_id: ctx.parent}, %CallContext{})
           |> tool_error() =~ "authenticated"
  end

  defp message!(target, text, actor \\ @operator) do
    {:ok, message, :created} =
      OperatorMessages.submit(
        target,
        text,
        [actor: actor, idempotency_key: uid("current-key")],
        fn _message -> {:ok, :queued} end
      )

    message
  end

  defp update!(row, fields), do: row |> Ecto.Changeset.change(fields) |> Repo.update!()
end
