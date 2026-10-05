defmodule Custode.TowerReturnFlowTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    ContextReceipts,
    Feed,
    Repo,
    ReturnViews,
    SubAgents,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  alias Custode.MCP.Identity
  alias Snodo.Client

  @human %{kind: :operator, id: "tower-proof-human"}
  @finding "research/rmcp-update.md"
  @decision "decisions/pr-review.md"
  # Verified reference data only. The fixture never reads or assesses this PR.
  @pr "https://github.com/genagent/custode/pull/829"
  @old_report "Synthetic historical owner report: approve from an obsolete finding"

  setup do
    parent = routine_fixture!(tmp_workspace!())
    first = %{kind: :sub_agent, id: uid("tower-producer")}
    second = %{kind: :sub_agent, id: uid("tower-reader")}
    workspace = tmp_workspace!()
    SubAgents.record_spawn!(first.id, parent.id, %{workspace: workspace})
    root = tmp_workspace!()
    for path <- ["research", "decisions"], do: File.mkdir!(Path.join(root, path))

    definition = %{
      id: uid("tower-subject"),
      subject: "Controlled Tower return proof",
      path: root,
      current_plan: @decision,
      grants: [
        %{
          kind: :sub_agent,
          id: first.id,
          read_paths: [@finding, @decision],
          create_paths: [@finding]
        },
        %{kind: :sub_agent, id: second.id, read_paths: [@finding, @decision]}
      ]
    }

    put_env!(:subject_roots, [definition])

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      Repo.delete_all(from(r in ContextReceipts.Row, where: r.root_id == ^definition.id))
      Repo.delete_all(from(r in ReturnViews.Feedback, where: r.root_id == ^definition.id))
      Repo.delete_all(from(r in SubjectDocuments.Operation, where: r.root_id == ^definition.id))
      Repo.delete_all(from(r in Feed.Entry, where: r.agent == ^parent.id))
      for actor <- [first, second], do: SubAgents.forget(actor.id)
    end)

    %{
      root: root,
      definition: definition,
      parent: parent,
      first: first,
      second: second,
      workspace: workspace
    }
  end

  for protocol <- ["2025-06-18", "2026-07-28"] do
    @protocol protocol
    test "Tower current finding and decision survive cleanup and edits on #{@protocol}", ctx do
      before_jobs = own_job_ids(ctx)
      ctx = publish_and_retire(ctx)
      token = Identity.mint(:sub_agent, ctx.second.id)

      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: @protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      try do
        {finding, finding_text} = read!(client, ctx, @finding)
        {decision, decision_text} = read!(client, ctx, @decision)
        assert finding["content"] == ctx.finding_content
        assert decision["content"] == ctx.decision_content
        assert decision["content"] =~ @pr
        assert decision["content"] =~ "Decision: synthetic defer"
        assert finding["content"] =~ "Checked: 2026-10-04"
        assert finding["content"] =~ "Source: controlled upstream fixture"
        assert finding["content"] =~ "Uncertainty:"
        assert_current_projection!(client, ctx, finding, decision)
        assert_retained!(client, finding, finding_text)
        assert_retained!(client, decision, decision_text)
        assert_decision_edit!(client, ctx, decision, decision_text)
        assert_retained!(client, finding, finding_text)
        assert own_job_ids(ctx) == before_jobs
        assert File.read!(Path.join(ctx.root, @finding)) == ctx.finding_content
      after
        Client.close(client)
      end
    end
  end

  defp publish_and_retire(ctx) do
    finding =
      "# Controlled synthetic rmcp finding\nChecked: 2026-10-04\n" <>
        "Source: controlled upstream fixture, https://example.invalid/rmcp/issue/7\n" <>
        "Uncertainty: compatibility is unverified; not real upstream research.\n"

    decision =
      "# Controlled human decision\nFixture only; no remote PR assessment.\n" <>
        "PR reference: #{@pr}\nDecision: synthetic defer pending compatibility evidence.\n"

    assert {:ok, publication} =
             SubjectDocuments.invoke(
               ctx.first,
               arguments(ctx, "create", @finding, %{
                 "content" => finding,
                 "request_id" => uid("tower-publication")
               })
             )

    File.write!(Path.join(ctx.root, @decision), decision)
    Feed.record(%{event: "turn", agent: ctx.parent.id, summary: @old_report})
    SubAgents.forget(ctx.first.id)
    File.rm_rf!(ctx.workspace)
    refute File.exists?(ctx.workspace)
    assert File.dir?(ctx.root)

    assert {:error, "current_helper_unavailable"} =
             SubjectDocuments.invoke(ctx.first, arguments(ctx, "read", @finding))

    SubAgents.record_spawn!(ctx.second.id, ctx.parent.id, %{workspace: tmp_workspace!()})

    Map.merge(ctx, %{
      finding_content: finding,
      decision_content: decision,
      publication: publication
    })
  end

  defp assert_current_projection!(client, ctx, finding, decision) do
    outputs = call!(client, "return_context", arguments(ctx, "outputs"))

    assert Enum.sort(Enum.map(outputs["outputs"], & &1["path"])) ==
             Enum.sort([@finding, @decision])

    assert outputs["reports"] == "separate_agent_authored_evidence"
    refute Jason.encode!(outputs) =~ @old_report

    detail = call!(client, "return_context", arguments(ctx, "detail", @finding))
    assert detail["content"] == finding["content"]
    assert detail["revision"] == finding["revision"]
    assert detail["disposition"] == "document_not_acceptance"
    refute detail["opening_resumes_work"]
    assert detail["navigation"]["current_plan"]["path"] == @decision
    assert detail["navigation"]["current_plan"]["revision"] == decision["revision"]

    assert {:ok, original} = ReturnViews.invoke(@human, arguments(ctx, "detail", @finding))
    assert [production] = original["navigation"]["productions"]
    assert production["published_revision"] == ctx.publication["revision"]
    assert production["recorded_owner"]["id"] == ctx.parent.id
    assert production["helper"]["record"]["registry_state"] == "removed"

    decision_detail = call!(client, "return_context", arguments(ctx, "detail", @decision))
    assert decision_detail["content"] == ctx.decision_content
    assert decision_detail["production_receipts"] == []
    assert decision_detail["disposition"] == "document_not_acceptance"
    refute Jason.encode!(decision_detail) =~ @old_report
  end

  defp assert_decision_edit!(client, ctx, decision, original_text) do
    feedback =
      arguments(ctx, "feedback", @decision, %{
        "expected_revision" => decision["revision"],
        "start_line" => 4,
        "end_line" => 4,
        "comment" => "Controlled question about this synthetic condition",
        "request_id" => uid("tower-feedback")
      })

    record = call!(client, "return_context", feedback)
    assert record["effect"] == "comment_only_no_apply_no_approval"
    assert record["anchor"]["selected_text_preview"] =~ "Decision: synthetic defer"
    assert File.read!(Path.join(ctx.root, @decision)) == ctx.decision_content

    revised =
      "# Controlled revised human decision\nPR reference: #{@pr}\n" <>
        "Decision: synthetic remain deferred; require the new compatibility condition.\n"

    File.write!(Path.join(ctx.root, @decision), revised)

    assert {:ok, %{"isError" => true, "content" => [%{"text" => refusal}]}} =
             Client.call_tool(client, "return_context", feedback)

    assert refusal =~ "revision_changed_reread_and_reanchor"
    {current, _text} = read!(client, ctx, @decision)
    assert current["content"] == revised
    refute current["revision"] == decision["revision"]
    detail = call!(client, "return_context", arguments(ctx, "detail", @decision))
    assert detail["content"] == revised
    assert [%{"anchor_state" => "historical"}] = detail["feedback"]
    assert_retained!(client, decision, original_text)
    assert_expired!(client, decision)
    assert File.read!(Path.join(ctx.root, @decision)) == revised
  end

  defp assert_retained!(client, document, exact_text) do
    id = document["context_receipt_id"]

    eventually(fn ->
      assert Repo.get!(ContextReceipts.Row, id).record["state"] == "server_emitted"
    end)

    receipt = call!(client, "return_context", %{"action" => "context", "receipt_id" => id})
    assert receipt["state"] == "server_emitted"
    assert receipt["revision"] == document["revision"]
    assert receipt["exact_tool_text"] == exact_text
    assert receipt["model_received"] == "unknown"
    assert receipt["tokens"] == nil
  end

  defp assert_expired!(client, document) do
    row = Repo.get!(ContextReceipts.Row, document["context_receipt_id"])
    record = Map.put(row.record, "expires_at", "2020-01-01T00:00:00Z")
    row |> Ecto.Changeset.change(record: record) |> Repo.update!()

    receipt =
      call!(client, "return_context", %{"action" => "context", "receipt_id" => row.receipt_id})

    assert receipt["payload_state"] == "expired"
    assert receipt["exact_tool_text"] == nil
  end

  defp own_job_ids(ctx) do
    ids = [ctx.parent.id, ctx.first.id, ctx.second.id]

    Repo.all(
      from(job in Oban.Job,
        where:
          fragment("json_extract(?, '$.agent_id')", job.meta) in ^ids or
            fragment("json_extract(?, '$.agent_id')", job.args) in ^ids,
        order_by: job.id,
        select: job.id
      )
    )
  end

  defp read!(client, ctx, path) do
    assert {:ok, %{"content" => [%{"text" => text}]} = result} =
             Client.call_tool(client, "subject_context", arguments(ctx, "read", path))

    refute result["isError"]
    {Jason.decode!(text), text}
  end

  defp call!(client, tool, params) do
    assert {:ok, %{"content" => [%{"text" => text}]} = result} =
             Client.call_tool(client, tool, params)

    refute result["isError"]
    Jason.decode!(text)
  end

  defp arguments(ctx, action, path \\ nil, extras \\ %{}) do
    params = Map.merge(%{"action" => action, "root_id" => ctx.definition.id}, extras)
    if path, do: Map.put(params, "path", path), else: params
  end
end
