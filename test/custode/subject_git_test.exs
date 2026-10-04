defmodule Custode.SubjectGitTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Custode.MCP.{Identity, ToolPolicy}
  alias Custode.{Repo, SubAgents, SubjectDocumentBridge, SubjectDocuments}
  alias Custode.SubjectDocumentBridge.Binding
  alias Snodo.Client
  @human %{kind: :operator, id: "git-docs-human"}
  @path "research/source.md"

  setup do
    parent = routine_fixture!(tmp_workspace!())
    helper = uid("git-reader")
    root = tmp_workspace!()
    File.mkdir!(Path.join(root, "research"))
    File.write!(Path.join(root, @path), "Committed source with uncertainty.\n")
    File.write!(Path.join(root, "private.md"), "Unrelated private source.\n")
    git!(root, ["init", "--quiet"])
    git!(root, ["add", "."])
    commit!(root, "feat: record controlled subject Git fixture")
    head = String.trim(git!(root, ["rev-parse", "HEAD"]))
    SubAgents.record_spawn!(helper, parent.id, %{workspace: tmp_workspace!()})

    definition = %{
      id: uid("git-subject-root"),
      path: root,
      subject: "Travel",
      grants: [%{kind: :sub_agent, id: helper, read_paths: [@path]}]
    }

    put_env!(:subject_roots, [definition])

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      SubAgents.forget(helper)
      if binding = Repo.get(Binding, definition.id), do: Repo.delete!(binding)
    end)

    %{root: root, definition: definition, reader: %{kind: :sub_agent, id: helper}, head: head}
  end

  test "history and diff read exact current source while preserving repository state", ctx do
    File.write!(Path.join(ctx.root, "private.md"), "Staged private correction.\n")
    git!(ctx.root, ["add", "private.md"])
    File.write!(Path.join(ctx.root, "private.md"), "Unstaged private correction.\n")
    File.write!(Path.join(ctx.root, @path), "Current human source with a new uncertainty.\n")
    index = File.read!(Path.join(ctx.root, ".git/index"))
    status = git!(ctx.root, ["status", "--porcelain"])

    assert {:ok, current} = read(ctx.reader, ctx, "read")
    assert {:ok, history} = read(ctx.reader, ctx, "history")
    assert history["git_revision"] == ctx.head
    assert history["revision"] == current["revision"]
    assert [%{"git_revision" => revision, "committed_at_unix" => at}] = history["history"]
    assert revision == ctx.head
    assert is_integer(at)
    refute history["has_more"]
    refute history["rename_following"]

    assert {:ok, diff} = read(ctx.reader, ctx, "diff")
    assert diff["revision"] == current["revision"]
    assert diff["git_revision"] == ctx.head
    assert diff["base_revision"] != current["revision"]
    assert diff["tracked_at_head"]
    assert diff["read_only"]
    assert diff["comparison"] == "pinned_head_to_current_working_bytes"
    assert diff["diff"] =~ "-Committed source"
    assert diff["diff"] =~ "+Current human source"
    refute Jason.encode!(diff) =~ "private correction"
    refute Jason.encode!(history) =~ "gmail.com"
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
    assert git!(ctx.root, ["status", "--porcelain"]) == status
    assert String.trim(git!(ctx.root, ["rev-parse", "HEAD"])) == ctx.head
  end

  test "exact grants, current identity and strict arguments guard both Git reads", ctx do
    for action <- ~w(history diff) do
      assert {:error, "path_or_destination_not_granted"} =
               SubjectDocuments.invoke(ctx.reader, %{
                 "action" => action,
                 "root_id" => ctx.definition.id,
                 "path" => "private.md"
               })

      assert {:error, "invalid_arguments"} =
               SubjectDocuments.invoke(ctx.reader, %{
                 "action" => action,
                 "root_id" => ctx.definition.id,
                 "path" => @path,
                 "ref" => "HEAD~1"
               })
    end

    put_env!(:subject_roots, [%{ctx.definition | grants: []}])
    assert {:error, "root_not_granted"} = read(ctx.reader, ctx, "history")
    put_env!(:subject_roots, [ctx.definition])
    SubAgents.forget(ctx.reader.id)
    assert {:error, "current_helper_unavailable"} = read(ctx.reader, ctx, "diff")
    assert {:ok, _human_read} = read(@human, ctx, "history")
  end

  test "history never follows a renamed document into its previous ungranted path", ctx do
    git!(ctx.root, ["mv", @path, "research/renamed.md"])
    commit!(ctx.root, "feat: rename controlled subject source")
    renamed = String.trim(git!(ctx.root, ["rev-parse", "HEAD"]))
    grant = %{kind: :sub_agent, id: ctx.reader.id, read_paths: ["research/renamed.md"]}
    put_env!(:subject_roots, [%{ctx.definition | grants: [grant]}])

    assert {:ok, result} =
             SubjectDocuments.invoke(ctx.reader, %{
               "action" => "history",
               "root_id" => ctx.definition.id,
               "path" => "research/renamed.md"
             })

    assert Enum.map(result["history"], & &1["git_revision"]) == [renamed]
    refute Jason.encode!(result) =~ ctx.head
    refute result["rename_following"]
  end

  test "an absent repository is explicit and source symlinks never become Git reads", ctx do
    File.rename!(Path.join(ctx.root, ".git"), Path.join(ctx.root, "saved-git"))
    assert {:error, "git_repository_or_metadata_unavailable"} = read(ctx.reader, ctx, "history")
    assert {:ok, current} = read(ctx.reader, ctx, "read")
    assert current["git_revision"] == nil
    assert current["content"] =~ "Committed source"
    File.rename!(Path.join(ctx.root, "saved-git"), Path.join(ctx.root, ".git"))
    File.rm!(Path.join(ctx.root, @path))
    File.ln_s!(Path.join(ctx.root, "private.md"), Path.join(ctx.root, @path))
    assert {:error, _refused} = read(ctx.reader, ctx, "diff")
  end

  test "authenticated Snodo protocols expose scoped history and current working diff", ctx do
    token = Identity.mint(:sub_agent, ctx.reader.id)
    File.write!(Path.join(ctx.root, @path), "Human edit before HTTP read.\n")

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      for action <- ~w(history diff) do
        assert {:ok, %{"content" => [%{"text" => text}]}} =
                 Client.call_tool(client, "subject_context", %{
                   "action" => action,
                   "root_id" => ctx.definition.id,
                   "path" => @path
                 })

        result = Jason.decode!(text)
        assert result["git_revision"] == ctx.head
        assert result["read_only"]
        assert result["read_is_not_write_authority"]
        if action == "diff", do: assert(result["diff"] =~ "+Human edit before HTTP read")

        assert {:ok, %{"isError" => true}} =
                 Client.call_tool(client, "subject_context", %{
                   "action" => action,
                   "root_id" => ctx.definition.id,
                   "path" => "private.md"
                 })
      end

      assert :ok = Client.close(client)
    end

    assert ToolPolicy.fetch("subject_context") == {:ok, :self_write}
  end

  defp read(actor, ctx, action),
    do:
      SubjectDocuments.invoke(actor, %{
        "action" => action,
        "root_id" => ctx.definition.id,
        "path" => @path
      })

  defp git!(root, argv) do
    assert {output, 0} = System.cmd("git", argv, cd: root, stderr_to_stdout: true)
    output
  end

  defp commit!(root, message),
    do:
      git!(root, [
        "-c",
        "user.name=joshrotenberg",
        "-c",
        "user.email=joshrotenberg@gmail.com",
        "commit",
        "--quiet",
        "-m",
        message
      ])
end
