defmodule Custode.ReturnViewsTest do
  use ExUnit.Case, async: false
  import Ecto.Query, only: [from: 2]
  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.{
    ContextReceipts,
    Repo,
    ReturnViews,
    SubAgents,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  alias Custode.MCP.{CallContext, Identity}
  alias Snodo.Client
  @endpoint CustodeWeb.Endpoint
  @human %{kind: :operator, id: "return-human"}

  setup do
    parent = routine_fixture!(tmp_workspace!())
    first = uid("return-worker")
    second = uid("return-worker")

    for id <- [first, second],
        do: SubAgents.record_spawn!(id, parent.id, %{workspace: tmp_workspace!()})

    root = tmp_workspace!()

    definition = %{
      id: uid("return-root"),
      subject: "Tower and Travel",
      path: root,
      grants:
        Enum.map(
          [first, second],
          &%{kind: :sub_agent, id: &1, read_paths: "all", create_paths: ["research.md"]}
        )
    }

    put_env!(:subject_roots, [definition])
    File.write!(Path.join(root, "preferences.md"), "No car.\nUse trains.\n")

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      Repo.delete_all(ReturnViews.Feedback)
      Repo.delete_all(ContextReceipts.Row)
      Repo.delete_all(SubjectDocuments.Operation)
      Repo.delete_all(SubjectDocumentBridge.Binding)
      for id <- [first, second], do: SubAgents.forget(id)
    end)

    %{
      root: root,
      definition: definition,
      first: %{kind: :sub_agent, id: first},
      second: %{kind: :sub_agent, id: second}
    }
  end

  test "current outputs survive producer cleanup and retain honest production references", ctx do
    assert {:ok, _} =
             SubjectDocuments.invoke(ctx.first, %{
               "action" => "create",
               "root_id" => ctx.definition.id,
               "path" => "research.md",
               "content" => "Fixture upstream finding, not accepted.\n",
               "request_id" => uid("return-create")
             })

    workspace = SubAgents.get(ctx.first.id).workspace
    SubAgents.forget(ctx.first.id)
    File.rm_rf!(workspace)
    File.write!(Path.join(ctx.root, "research.md"), "Human corrected the upstream finding.\n")
    assert {:ok, projection} = view(ctx.second, ctx, "outputs")
    output = Enum.find(projection["outputs"], &(&1["path"] == "research.md"))
    assert output["production_receipts"] |> hd() |> get_in(["actor", "id"]) == ctx.first.id
    assert output["disposition"] == "document_not_acceptance"
    assert {:ok, detail} = view(ctx.second, ctx, "detail", %{"path" => "research.md"})
    assert detail["content"] =~ "Human corrected"
    refute detail["opening_resumes_work"]
    assert {:ok, _} = view(@human, ctx, "detail", %{"path" => "preferences.md"})
  end

  test "feedback binds exact revision and lines and cannot apply or approve", ctx do
    assert {:ok, doc} = view(@human, ctx, "detail", %{"path" => "preferences.md"})

    params = %{
      "path" => "preferences.md",
      "expected_revision" => doc["revision"],
      "start_line" => 1,
      "end_line" => 2,
      "comment" => "Clarify transit preference",
      "request_id" => uid("feedback")
    }

    assert {:ok, original} = view(@human, ctx, "feedback", params)
    assert {:ok, ^original} = view(@human, ctx, "feedback", params)
    assert original["effect"] == "comment_only_no_apply_no_approval"
    assert File.read!(Path.join(ctx.root, "preferences.md")) == "No car.\nUse trains.\n"

    assert {:error, "invalid_line_span"} =
             view(@human, ctx, "feedback", %{params | "end_line" => 100})

    File.write!(Path.join(ctx.root, "preferences.md"), "Prefer Camogli.\n")

    assert {:error, "revision_changed_reread_and_reanchor"} =
             view(@human, ctx, "feedback", params)

    assert Repo.aggregate(
             from(row in ReturnViews.Feedback, where: row.root_id == ^ctx.definition.id),
             :count
           ) == 1
  end

  test "prepared text and nonmatching or chunked sends do not become delivery evidence", ctx do
    params = %{"action" => "read", "root_id" => ctx.definition.id, "path" => "preferences.md"}
    assert {:ok, doc} = SubjectDocuments.invoke(ctx.first, params)
    id = Ecto.UUID.generate()
    frame = %CallContext{assigns: %{custode_identity: ctx.first, custode_delivery_id: id}}
    assert {:ok, text} = ContextReceipts.prepare(frame, params, doc)
    assert {:ok, receipt} = ContextReceipts.read(ctx.first, id)
    assert receipt["state"] == "prepared"

    conn =
      %{
        build_conn()
        | state: :sent,
          status: 200,
          resp_body: Jason.encode!(%{result: %{content: [%{text: "wrong"}]}})
      }
      |> Plug.Conn.assign(:custode_delivery_id, id)

    ContextReceipts.emitted(conn)
    ContextReceipts.emitted(%{conn | state: :chunked})
    assert Repo.get!(ContextReceipts.Row, id).record["state"] == "prepared"
    conn = %{conn | resp_body: Jason.encode!(%{result: %{content: [%{text: text}]}})}
    ContextReceipts.emitted(conn)
    assert {:ok, emitted} = ContextReceipts.read(ctx.first, id)
    assert emitted["state"] == "server_emitted"
    assert emitted["model_received"] == "unknown"
    assert emitted["execution_binding"] =~ "unknown"
    assert emitted["exact_tool_text"] == text
    assert {:error, "context_receipt_not_granted"} = ContextReceipts.read(ctx.second, id)
  end

  test "expired and retired context never substitutes current content", ctx do
    params = %{"action" => "read", "root_id" => ctx.definition.id, "path" => "preferences.md"}
    assert {:ok, doc} = SubjectDocuments.invoke(ctx.first, params)
    id = Ecto.UUID.generate()
    frame = %CallContext{assigns: %{custode_identity: ctx.first, custode_delivery_id: id}}
    assert {:ok, text} = ContextReceipts.prepare(frame, params, doc)
    File.write!(Path.join(ctx.root, "preferences.md"), "Different current preference.\n")
    assert {:ok, old} = ContextReceipts.read(@human, id)
    assert old["exact_tool_text"] == text
    row = Repo.get!(ContextReceipts.Row, id)

    row
    |> Ecto.Changeset.change(record: Map.put(row.record, "expires_at", "2020-01-01T00:00:00Z"))
    |> Repo.update!()

    assert {:ok, expired} = ContextReceipts.read(@human, id)
    assert expired["payload_state"] == "expired"
    assert expired["exact_tool_text"] == nil
    assert {:ok, contexts} = view(ctx.first, ctx, "contexts")
    assert hd(contexts)["payload_state"] == "expired"
    put_env!(:subject_roots, [%{ctx.definition | grants: []}])
    assert {:error, "root_not_granted"} = ContextReceipts.read(ctx.first, id)
    assert {:error, "root_not_granted"} = view(ctx.first, ctx, "contexts")
  end

  test "actual authenticated HTTP responses retain exact tool text on both protocols", ctx do
    token = Identity.mint(:sub_agent, ctx.first.id)

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, %{"content" => [%{"text" => text}]}} =
               Client.call_tool(client, "subject_context", %{
                 "action" => "read",
                 "root_id" => ctx.definition.id,
                 "path" => "preferences.md"
               })

      id = Jason.decode!(text)["context_receipt_id"]
      assert is_binary(id)
      wait_until(fn -> Repo.get!(ContextReceipts.Row, id).record["state"] == "server_emitted" end)

      assert {:ok, %{"content" => [%{"text" => receipt_text}]}} =
               Client.call_tool(client, "return_context", %{
                 "action" => "context",
                 "receipt_id" => id
               })

      receipt = Jason.decode!(receipt_text)
      assert receipt["exact_tool_text"] == text
      assert receipt["model_received"] == "unknown"
      assert :ok = Client.close(client)
    end
  end

  test "compact UI opens current documents and refuses feedback after an external edit", ctx do
    jobs = Repo.aggregate(Oban.Job, :count)
    route = "/subjects/#{ctx.definition.id}?file=preferences.md"
    assert {:ok, liveview, _} = live(build_conn(), route)
    assert has_element?(liveview, "#subject-document", "No car.")
    assert has_element?(liveview, "#document-producers summary", "Recorded production")
    File.write!(Path.join(ctx.root, "preferences.md"), "Current corrected preference.\n")

    result =
      liveview
      |> form("#document-feedback", %{start_line: "1", end_line: "1", comment: "old"})
      |> render_submit()

    assert result =~ "revision_changed_reread_and_reanchor"

    assert Repo.aggregate(
             from(row in ReturnViews.Feedback, where: row.root_id == ^ctx.definition.id),
             :count
           ) == 0

    assert Repo.aggregate(Oban.Job, :count) == jobs
  end

  test "payload retention keeps only the latest hundred and metadata remains explicit", ctx do
    params = %{"action" => "read", "root_id" => ctx.definition.id, "path" => "preferences.md"}
    assert {:ok, doc} = SubjectDocuments.invoke(ctx.first, params)

    ids =
      for _ <- 1..101 do
        id = Ecto.UUID.generate()
        frame = %CallContext{assigns: %{custode_identity: ctx.first, custode_delivery_id: id}}
        assert {:ok, _text} = ContextReceipts.prepare(frame, params, doc)
        id
      end

    assert {:ok, retired} = ContextReceipts.read(@human, hd(ids))
    assert retired["payload_state"] == "expired"
    assert retired["exact_tool_text"] == nil
    assert {:ok, newest} = ContextReceipts.read(@human, List.last(ids))
    assert newest["payload_state"] == "retained"
    key = "sub_agent:" <> ctx.first.id

    assert Repo.aggregate(from(row in ContextReceipts.Row, where: row.actor_key == ^key), :count) ==
             101
  end

  test "historical payload authority survives source deletion but not revoked identity", ctx do
    params = %{"action" => "read", "root_id" => ctx.definition.id, "path" => "preferences.md"}
    assert {:ok, doc} = SubjectDocuments.invoke(ctx.first, params)
    id = Ecto.UUID.generate()
    frame = %CallContext{assigns: %{custode_identity: ctx.first, custode_delivery_id: id}}
    assert {:ok, text} = ContextReceipts.prepare(frame, params, doc)
    File.rm!(Path.join(ctx.root, "preferences.md"))
    assert {:ok, original} = ContextReceipts.read(ctx.first, id)
    assert original["exact_tool_text"] == text
    assert {:error, "unauthenticated"} = ContextReceipts.read(%{}, id)
    SubAgents.forget(ctx.first.id)
    assert {:error, "current_helper_unavailable"} = ContextReceipts.read(ctx.first, id)
    assert {:ok, _retained} = ContextReceipts.read(@human, id)
  end

  defp wait_until(fun, tries \\ 50)

  defp wait_until(fun, tries) when tries > 0 do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          wait_until(fun, tries - 1)
        )
  end

  defp wait_until(_fun, 0), do: flunk("server emission receipt was not observed")

  defp view(actor, ctx, action, args \\ %{}),
    do:
      ReturnViews.invoke(
        actor,
        Map.merge(%{"action" => action, "root_id" => ctx.definition.id}, args)
      )
end
