defmodule Custode.ReturnFeedbackTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]
  alias Custode.MCP.{Identity, ToolPolicy}
  alias Custode.{Repo, ReturnViews, SubAgents, SubjectDocumentBridge}
  alias Snodo.Client
  @endpoint CustodeWeb.Endpoint
  @path "preferences.md"

  setup do
    root = tmp_workspace!()
    parent = routine_fixture!(tmp_workspace!())
    helper = uid("anchor-reader")
    SubAgents.record_spawn!(helper, parent.id, %{workspace: tmp_workspace!()})
    File.write!(Path.join(root, @path), "Use a car.\nConsider coast.\n")
    File.write!(Path.join(root, "decision.md"), "Tower decision: review pending.\n")
    git!(root, ["init", "--quiet"])
    git!(root, ["add", "."])
    commit!(root)

    definition = %{
      id: uid("anchor-root"),
      path: root,
      subject: "Tower and Travel",
      grants: [%{kind: :sub_agent, id: helper, read_paths: [@path]}]
    }

    put_env!(:subject_roots, [definition])
    File.write!(Path.join(root, @path), "No car.\nConsider coast.\n")

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      Repo.delete_all(from(row in ReturnViews.Feedback, where: row.root_id == ^definition.id))
      if row = Repo.get(SubjectDocumentBridge.Binding, definition.id), do: Repo.delete!(row)
      SubAgents.forget(helper)
    end)

    %{root: root, definition: definition, reader: %{kind: :sub_agent, id: helper}}
  end

  test "span feedback is exact, idempotent and comment only", ctx do
    File.write!(Path.join(ctx.root, @path), "Travel 👨‍👩‍👧‍👦é without car.\n")
    assert {:ok, doc} = view(ctx, "detail")
    params = feedback(doc, span(1, 8, 1, 10))
    assert {:ok, record} = view(ctx, "feedback", params)
    assert record["anchor"]["selected_text_preview"] == "👨‍👩‍👧‍👦é"
    assert record["effect"] == "comment_only_no_apply_no_approval"
    assert {:ok, ^record} = view(ctx, "feedback", params)

    assert {:error, "idempotency_conflict"} =
             view(ctx, "feedback", %{params | "comment" => "Different"})

    assert File.read!(Path.join(ctx.root, @path)) == doc["content"]

    assert {:error, "ambiguous_feedback_anchor"} =
             view(ctx, "feedback", Map.put(params, "start_line", 1))
  end

  test "scoped hunk feedback preserves source, HEAD, index and unrelated changes", ctx do
    File.write!(Path.join(ctx.root, "decision.md"), "Staged Tower decision.\n")
    git!(ctx.root, ["add", "decision.md"])
    File.write!(Path.join(ctx.root, "decision.md"), "Unstaged Tower decision.\n")
    index = File.read!(Path.join(ctx.root, ".git/index"))
    status = git!(ctx.root, ["status", "--porcelain"])
    head = git!(ctx.root, ["rev-parse", "HEAD"])
    assert {:ok, diff} = view(ctx, "diff")
    assert [%{"text" => text}] = diff["hunks"]
    assert text =~ "+No car."
    assert {:ok, record} = view(ctx, "feedback", feedback(diff, hunk(diff)))
    assert record["anchor"]["selected_text_preview"] == text
    assert {:ok, detail} = view(ctx, "detail")
    assert hd(detail["feedback"])["anchor_state"] == "current"
    assert File.read!(Path.join(ctx.root, @path)) == "No car.\nConsider coast.\n"
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
    assert git!(ctx.root, ["status", "--porcelain"]) == status
    assert git!(ctx.root, ["rev-parse", "HEAD"]) == head
    assert File.read!(Path.join(ctx.root, "decision.md")) == "Unstaged Tower decision.\n"
  end

  test "external source edits refuse old spans and hunks and preserve historical evidence", ctx do
    assert {:ok, doc} = view(ctx, "detail")
    span_params = feedback(doc, span(1, 1, 1, 3))
    assert {:ok, _record} = view(ctx, "feedback", span_params)
    assert {:ok, diff} = view(ctx, "diff")
    hunk_params = feedback(diff, hunk(diff))
    File.write!(Path.join(ctx.root, @path), "Use trains instead.\n")

    for params <- [span_params, hunk_params] do
      assert {:error, "revision_changed_reread_and_reanchor"} = view(ctx, "feedback", params)
    end

    assert {:ok, detail} = view(ctx, "detail")
    assert [%{"anchor_state" => "historical", "anchor" => anchor}] = detail["feedback"]
    assert anchor["selected_text_preview"] == "No"
  end

  test "an unrelated new HEAD invalidates hunk anchors even when source bytes and diff text match",
       ctx do
    assert {:ok, diff} = view(ctx, "diff")
    params = feedback(diff, hunk(diff))
    assert {:ok, _record} = view(ctx, "feedback", params)
    File.write!(Path.join(ctx.root, "decision.md"), "Tower decision now accepted by human.\n")
    git!(ctx.root, ["add", "decision.md"])
    commit!(ctx.root)
    assert {:ok, updated} = view(ctx, "diff")
    assert updated["revision"] == diff["revision"]
    assert Enum.map(updated["hunks"], & &1["text"]) == Enum.map(diff["hunks"], & &1["text"])
    refute updated["git_revision"] == diff["git_revision"]
    assert {:error, "diff_changed_reread_and_reanchor"} = view(ctx, "feedback", params)
    assert {:ok, detail} = view(ctx, "detail")

    assert [%{"matches_current_revision" => true, "anchor_state" => "historical"}] =
             detail["feedback"]
  end

  test "missing Git cannot relabel a retained hunk as current", ctx do
    assert {:ok, diff} = view(ctx, "diff")
    assert {:ok, _record} = view(ctx, "feedback", feedback(diff, hunk(diff)))
    File.rename!(Path.join(ctx.root, ".git"), Path.join(ctx.root, "saved-git"))
    assert {:error, "git_repository_or_metadata_unavailable"} = view(ctx, "diff")
    assert {:ok, detail} = view(ctx, "detail")

    assert [%{"matches_current_revision" => true, "anchor_state" => "current_diff_unavailable"}] =
             detail["feedback"]

    assert detail["content"] =~ "No car."
  end

  test "unborn HEAD and exact current grants remain explicit", ctx do
    git!(ctx.root, ["update-ref", "-d", "HEAD"])
    assert {:ok, diff} = view(ctx, "diff")
    assert diff["git_revision"] == nil
    assert hd(diff["hunks"])["old_count"] == 0
    assert {:ok, _record} = view(ctx, "feedback", feedback(diff, hunk(diff)))

    assert {:error, "path_or_destination_not_granted"} =
             view(ctx, "diff", %{"path" => "decision.md"})

    put_env!(:subject_roots, [%{ctx.definition | grants: []}])
    assert {:error, "root_not_granted"} = view(ctx, "feedback", feedback(diff, hunk(diff)))
  end

  test "both authenticated HTTP dialects share anchor reads and stale refusal", ctx do
    token = Identity.mint(:sub_agent, ctx.reader.id)

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      diff = call!(client, ctx, "diff")
      record = call!(client, ctx, "feedback", feedback(diff, hunk(diff)))
      assert record["anchor"]["kind"] == "diff_hunk"
      refute record["effect"] =~ "apply=true"

      assert {:ok, %{"isError" => true}} =
               Client.call_tool(client, "return_context", %{
                 "action" => "feedback",
                 "root_id" => ctx.definition.id,
                 "path" => @path,
                 "expected_revision" => diff["revision"],
                 "request_id" => uid("bad-anchor"),
                 "comment" => "stale",
                 "anchor" => %{hunk(diff) | "expected_diff_revision" => String.duplicate("a", 64)}
               })

      assert :ok = Client.close(client)
    end

    assert ToolPolicy.fetch("return_context") == {:ok, :self_write}
  end

  test "keyboard and pointer form controls submit shared spans and hunks, and reread stale content",
       ctx do
    path = "/subjects/" <> URI.encode_www_form(ctx.definition.id) <> "?file=" <> @path
    assert {:ok, live, _html} = live(build_conn(), path)
    assert has_element?(live, "button[phx-click='read_diff']")

    original_form = composer_id(live)

    live
    |> form("[data-role=document-feedback]", %{
      anchor_kind: "span",
      start_line: "1",
      end_line: "1",
      start_column: "1",
      end_column: "3",
      comment: "Exact word"
    })
    |> render_submit()

    assert render(live) =~ "Span 1:1 to 1:3 (exclusive)"
    assert render(live) =~ "Exact word"
    refute composer_id(live) == original_form
    assert composer_text(live) == ""
    second_form = composer_id(live)

    live |> element("button[phx-click='read_diff']") |> render_click()
    assert has_element?(live, "#document-diff")
    assert {:ok, diff} = view(ctx, "diff")

    live
    |> form("[data-role=document-feedback]", %{
      anchor_kind: "diff_hunk",
      hunk_id: hd(diff["hunks"])["hunk_id"],
      comment: "Review this hunk"
    })
    |> render_submit()

    assert render(live) =~ "Comment recorded"
    assert render(live) =~ "Review this hunk"
    assert render(live) =~ "Git hunk"
    refute composer_id(live) == second_form
    assert composer_text(live) == ""

    comments =
      Repo.all(from(row in ReturnViews.Feedback, where: row.root_id == ^ctx.definition.id))

    assert Enum.sort(Enum.map(comments, & &1.record["comment"])) == [
             "Exact word",
             "Review this hunk"
           ]

    live |> form("[data-role=document-feedback]", %{comment: ""}) |> render_submit()

    assert Repo.aggregate(
             from(row in ReturnViews.Feedback, where: row.root_id == ^ctx.definition.id),
             :count
           ) == 2

    File.write!(Path.join(ctx.root, @path), "New preference.\n")

    live
    |> form("[data-role=document-feedback]", %{
      anchor_kind: "span",
      start_line: "1",
      end_line: "1",
      start_column: "1",
      end_column: "3",
      comment: "Old selection"
    })
    |> render_submit()

    assert render(live) =~ "revision_changed_reread_and_reanchor"
    live |> element("button[phx-click='reread']") |> render_click()
    assert render(live) =~ "New preference."
    refute has_element?(live, "#document-diff")
  end

  defp composer_id(live),
    do:
      live
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("form[data-role=document-feedback]")
      |> LazyHTML.attribute("id")
      |> hd()

  defp composer_text(live),
    do:
      live
      |> render()
      |> LazyHTML.from_document()
      |> LazyHTML.query("form[data-role=document-feedback] textarea")
      |> LazyHTML.text()

  defp view(ctx, action, extra \\ %{}),
    do:
      ReturnViews.invoke(
        ctx.reader,
        Map.merge(%{"action" => action, "root_id" => ctx.definition.id, "path" => @path}, extra)
      )

  defp feedback(source, anchor),
    do: %{
      "expected_revision" => source["revision"],
      "request_id" => uid("anchor-comment"),
      "comment" => "Retain this selection",
      "anchor" => anchor
    }

  defp span(first, column, last, finish),
    do: %{
      "kind" => "span",
      "start_line" => first,
      "start_column" => column,
      "end_line" => last,
      "end_column" => finish
    }

  defp hunk(diff),
    do: %{
      "kind" => "diff_hunk",
      "expected_git_revision" => diff["git_revision"],
      "expected_diff_revision" => diff["diff_revision"],
      "hunk_id" => hd(diff["hunks"])["hunk_id"]
    }

  defp call!(client, ctx, action, extra \\ %{}) do
    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(
               client,
               "return_context",
               Map.merge(
                 %{"action" => action, "root_id" => ctx.definition.id, "path" => @path},
                 extra
               )
             )

    Jason.decode!(text)
  end

  defp git!(root, args) do
    assert {output, 0} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    output
  end

  defp commit!(root),
    do:
      git!(root, [
        "-c",
        "user.name=joshrotenberg",
        "-c",
        "user.email=joshrotenberg@gmail.com",
        "commit",
        "--quiet",
        "-m",
        "feat: record controlled feedback fixture"
      ])
end
