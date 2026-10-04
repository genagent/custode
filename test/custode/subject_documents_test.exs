defmodule Custode.SubjectDocumentsTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Custode.MCP.{CallContext, Identity, SubjectDocumentTools}
  alias Custode.{Repo, SubAgents, SubjectDocumentBridge, SubjectDocuments}
  alias Custode.SubjectDocumentBridge.Binding
  alias Custode.SubjectDocuments.Operation
  alias Snodo.Client
  @human %{kind: :operator, id: "docs-human"}

  setup do
    parent = routine_fixture!(tmp_workspace!())
    root_path = tmp_workspace!()
    first = uid("doc-worker")
    second = uid("doc-worker")

    for id <- [first, second],
        do: SubAgents.record_spawn!(id, parent.id, %{workspace: tmp_workspace!()})

    definition = %{
      id: uid("subject-root"),
      path: root_path,
      subject: "Travel",
      grants: [
        %{kind: :routine, id: parent.id, read_paths: "all"},
        %{
          kind: :sub_agent,
          id: first,
          read_paths: ["preferences.md"],
          create_paths: ["first-research.md"]
        },
        %{
          kind: :sub_agent,
          id: second,
          read_paths: ["preferences.md", "first-research.md"],
          create_paths: ["follow-up.md"]
        }
      ]
    }

    put_env!(:subject_roots, [definition])
    File.write!(Path.join(root_path, "preferences.md"), "No car. Stay near a train station.\n")

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      Repo.delete_all(Operation)
      Repo.delete_all(Binding)
      for id <- [first, second], do: SubAgents.forget(id)
    end)

    %{
      definition: definition,
      root: root_path,
      parent: parent,
      first: %{kind: :sub_agent, id: first},
      second: %{kind: :sub_agent, id: second}
    }
  end

  test "two fresh scoped workers use externally edited current context after producer cleanup",
       ctx do
    assert {:ok, initial} = call(ctx.first, ctx, "read", %{"path" => "preferences.md"})

    evidence =
      "# Liguria\nSource: fixture research, 2026-10-04.\nUncertainty: train schedules unverified.\nPreference revision: #{initial["revision"]}\n"

    params = %{
      "path" => "first-research.md",
      "content" => evidence,
      "request_id" => uid("first-create")
    }

    assert {:ok, output} = call(ctx.first, ctx, "create", params)
    assert output["receipt"]["producer"]["identity"]["id"] == ctx.first.id
    first_workspace = SubAgents.get(ctx.first.id).workspace
    SubAgents.forget(ctx.first.id)
    File.rm_rf!(first_workspace)

    File.write!(
      Path.join(ctx.root, "preferences.md"),
      "No car. Prefer Camogli and train access.\n"
    )

    assert {:ok, current} = call(ctx.second, ctx, "read", %{"path" => "preferences.md"})
    refute current["revision"] == initial["revision"]
    assert {:ok, research} = call(ctx.second, ctx, "read", %{"path" => "first-research.md"})
    assert research["content"] == evidence

    assert {:ok, _followup} =
             call(ctx.second, ctx, "create", %{
               "path" => "follow-up.md",
               "request_id" => uid("followup"),
               "content" => "Use #{current["revision"]} and #{research["revision"]}.\n"
             })

    assert File.regular?(Path.join(ctx.root, "follow-up.md"))

    assert {:error, "current_helper_unavailable"} =
             call(ctx.first, ctx, "read", %{"path" => "preferences.md"})

    assert {:ok, outputs} = SubjectDocuments.outputs(@human, ctx.definition.id)
    assert length(outputs) == 2
  end

  test "named reads, other helpers and current owners never imply write destinations", ctx do
    assert {:error, "path_or_destination_not_granted"} =
             call(ctx.first, ctx, "create", %{
               "path" => "preferences.md",
               "content" => "replace",
               "request_id" => uid("denied")
             })

    assert {:error, "path_or_destination_not_granted"} =
             call(%{kind: :routine, id: ctx.parent.id}, ctx, "create", %{
               "path" => "new.md",
               "content" => "not allowed",
               "request_id" => uid("denied")
             })

    assert {:error, "current_helper_unavailable"} =
             call(%{kind: :sub_agent, id: "invented"}, ctx, "read", %{"path" => "preferences.md"})

    assert {:error, "unauthenticated"} = call(%{}, ctx, "read", %{"path" => "preferences.md"})

    assert {:error, "path_or_destination_not_granted"} =
             call(ctx.first, ctx, "read", %{"path" => "ungranted.md"})
  end

  test "exclusive output requests remain idempotent while human edits remain authoritative",
       ctx do
    params = %{
      "path" => "first-research.md",
      "content" => "Original.\n",
      "request_id" => uid("create")
    }

    tasks =
      Enum.map(1..2, fn _ -> Task.async(fn -> call(ctx.first, ctx, "create", params) end) end)

    results = Enum.map(tasks, &Task.await(&1, 10_000))
    assert Enum.any?(results, &match?({:ok, _}, &1))
    assert {:ok, original} = call(ctx.first, ctx, "create", params)
    File.write!(Path.join(ctx.root, "first-research.md"), "Human correction.\n")
    assert {:ok, same} = call(ctx.first, ctx, "create", params)
    assert same == original
    assert same["source"] == "published_receipt_current_read_required"
    assert {:ok, current} = call(@human, ctx, "read", %{"path" => "first-research.md"})
    assert current["content"] == "Human correction.\n"

    assert {:error, "idempotency_conflict"} =
             call(ctx.first, ctx, "create", %{params | "content" => "other"})

    assert {:error, "destination_exists"} =
             call(ctx.first, ctx, "create", %{params | "request_id" => uid("duplicate")})

    assert File.read!(Path.join(ctx.root, "first-research.md")) == "Human correction.\n"
  end

  test "proposals bind source revision and never replace it or the git index", ctx do
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: ctx.root)
    {_, 0} = System.cmd("git", ["add", "preferences.md"], cd: ctx.root)
    index = File.read!(Path.join(ctx.root, ".git/index"))
    File.write!(Path.join(ctx.root, "unrelated.txt"), "keep me")
    assert {:ok, initial} = call(@human, ctx, "read", %{"path" => "preferences.md"})

    params = %{
      "path" => "preferences.md",
      "destination" => "proposal.md",
      "expected_revision" => initial["revision"],
      "content" => "Prefer a hotel by the station.\n",
      "request_id" => uid("proposal")
    }

    File.write!(Path.join(ctx.root, "preferences.md"), "New human preference.\n")
    assert {:error, stale} = call(@human, ctx, "propose", params)
    assert String.starts_with?(stale, "stale_revision:")
    refute File.exists?(Path.join(ctx.root, "proposal.md"))
    assert {:ok, current} = call(@human, ctx, "read", %{"path" => "preferences.md"})

    assert {:ok, proposal} =
             call(@human, ctx, "propose", %{
               params
               | "expected_revision" => current["revision"],
                 "request_id" => uid("proposal-current")
             })

    refute proposal["applied"]
    assert proposal["expected_revision"] == current["revision"]
    assert proposal["proposal"]["path"] == "proposal.md"
    assert proposal["diff"] =~ "New human preference"
    assert File.read!(Path.join(ctx.root, "preferences.md")) == "New human preference.\n"
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "keep me"
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
  end

  test "symlinks, traversal, missing directories, FIFOs and oversized files fail closed", ctx do
    outside = Path.join(tmp_workspace!(), "outside.md")
    File.write!(outside, "private outside bytes")
    File.ln_s!(outside, Path.join(ctx.root, "link.md"))

    for path <- ["link.md", "../outside.md", "nested/file.md", ".git/config.md"] do
      assert {:error, _reason} = call(@human, ctx, "read", %{"path" => path})
    end

    {_, 0} = System.cmd("mkfifo", [Path.join(ctx.root, "pipe.md")])
    assert {:error, "regular_file_required"} = call(@human, ctx, "read", %{"path" => "pipe.md"})
    File.write!(Path.join(ctx.root, "large.md"), String.duplicate("x", 16_385))
    assert {:error, "content_too_large"} = call(@human, ctx, "read", %{"path" => "large.md"})
    assert {:ok, browse} = call(@human, ctx, "browse")
    refute "link.md" in browse["paths"]
    refute "pipe.md" in browse["paths"]

    assert {:error, "git_boundary_unavailable"} =
             call(@human, ctx, "history", %{"path" => "preferences.md"})
  end

  test "root replacement cannot redirect operations, including after bridge restart", ctx do
    assert {:ok, _document} = call(@human, ctx, "read", %{"path" => "preferences.md"})
    old = ctx.root <> "-retained"
    outside = tmp_workspace!()
    File.write!(Path.join(outside, "preferences.md"), "outside secret")
    File.rename!(ctx.root, old)
    File.ln_s!(outside, ctx.root)
    assert {:error, "root_replaced"} = call(@human, ctx, "read", %{"path" => "preferences.md"})
    SubjectDocumentBridge.reset()

    assert {:error, "root_replaced"} =
             call(@human, ctx, "create", %{
               "path" => "new.md",
               "content" => "blocked",
               "request_id" => uid("replaced")
             })

    refute File.exists?(Path.join(outside, "new.md"))
    assert File.read!(Path.join(old, "preferences.md")) =~ "No car"
    File.rm!(ctx.root)
    File.rename!(old, ctx.root)
  end

  test "restart retains root identity and mutation receipts; absent helper is explicit", ctx do
    params = %{
      "path" => "created.md",
      "content" => "retained source and uncertainty",
      "request_id" => uid("persist")
    }

    assert {:ok, result} = call(@human, ctx, "create", params)
    binding = Repo.get!(Binding, ctx.definition.id).binding
    SubjectDocumentBridge.reset()
    assert {:ok, same} = call(@human, ctx, "create", params)
    assert same == result
    assert Repo.get!(Binding, ctx.definition.id).binding == binding
    assert {:ok, receipt} = call(@human, ctx, "receipt", %{"request_id" => params["request_id"]})
    assert receipt["status"] == "created"
    SubjectDocumentBridge.reset()
    put_env!(:subject_python, "/nonexistent/custode-python")

    assert {:error, "descriptor_helper_unavailable"} =
             call(@human, ctx, "read", %{"path" => "preferences.md"})
  end

  test "unknown crash outcomes are retained and never cause another write", ctx do
    params = %{
      "action" => "create",
      "root_id" => ctx.definition.id,
      "path" => "ambiguous.md",
      "content" => "wanted",
      "request_id" => uid("ambiguous")
    }

    fingerprint = SubjectDocuments.digest({@human, ctx.definition, params})

    Repo.insert!(%Operation{
      request_id: params["request_id"],
      root_id: ctx.definition.id,
      fingerprint: fingerprint,
      record: %{"status" => "prepared", "request" => params}
    })

    assert {:error, "operation_unconfirmed_do_not_retry_write"} =
             SubjectDocuments.invoke(@human, params)

    refute File.exists?(Path.join(ctx.root, "ambiguous.md"))
  end

  test "MCP shares scope and does not accept an actor or arbitrary root from parameters", ctx do
    frame = %CallContext{assigns: %{custode_identity: ctx.first}}

    assert %{"content" => content} =
             tool_json(
               SubjectDocumentTools.Context.execute(
                 %{action: "read", root_id: ctx.definition.id, path: "preferences.md"},
                 frame
               )
             )

    assert content =~ "No car"

    assert tool_error(SubjectDocumentTools.Context.execute(%{action: "roots"}, %CallContext{})) =~
             "authenticated"

    assert {:error, "invalid_arguments"} =
             SubjectDocuments.invoke(ctx.first, %{
               "action" => "read",
               "root_id" => ctx.definition.id,
               "path" => "preferences.md",
               "actor" => "operator"
             })
  end

  test "initial binding refuses a substituted root instead of adopting its outside contents",
       ctx do
    outside = tmp_workspace!()
    File.write!(Path.join(outside, "preferences.md"), "private outside source")
    old = ctx.root <> "-initial"
    File.rename!(ctx.root, old)
    File.ln_s!(outside, ctx.root)
    assert {:error, _refused} = call(@human, ctx, "read", %{"path" => "preferences.md"})
    assert Repo.get(Binding, ctx.definition.id) == nil
    File.rm!(ctx.root)
    File.rename!(old, ctx.root)
  end

  test "current grant withdrawal refuses old connections and historical mutation retries", ctx do
    params = %{"path" => "first-research.md", "content" => "source", "request_id" => uid("grant")}
    assert {:ok, _created} = call(ctx.first, ctx, "create", params)
    withdrawn = %{ctx.definition | grants: []}
    put_env!(:subject_roots, [withdrawn])
    assert {:error, "root_not_granted"} = call(ctx.first, ctx, "create", params)

    assert {:error, "root_not_granted"} =
             call(ctx.first, ctx, "read", %{"path" => "preferences.md"})

    assert {:ok, roots} = SubjectDocuments.invoke(ctx.first, %{"action" => "roots"})
    assert roots["roots"] == []
    assert File.regular?(Path.join(ctx.root, "first-research.md"))
  end

  test "real Snodo clients invoke scoped reads and creation on both supported protocol revisions",
       ctx do
    token = Identity.mint(:sub_agent, ctx.first.id)

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.any?(tools, &(&1["name"] == "subject_context"))

      assert {:ok, %{"content" => [%{"text" => body}]}} =
               Client.call_tool(client, "subject_context", %{
                 "action" => "read",
                 "root_id" => ctx.definition.id,
                 "path" => "preferences.md"
               })

      assert Jason.decode!(body)["content"] =~ "No car"

      assert {:ok, %{"isError" => true}} =
               Client.call_tool(client, "subject_context", %{
                 "action" => "create",
                 "root_id" => ctx.definition.id,
                 "path" => "not-granted.md",
                 "content" => "denied",
                 "request_id" => uid("http-denied")
               })

      assert :ok = Client.close(client)
    end
  end

  test "nested exact grants survive fresh workers and preserve current human context", ctx do
    for directory <- ~w(research plans), do: File.mkdir!(Path.join(ctx.root, directory))

    definition = %{
      ctx.definition
      | grants: [
          %{
            kind: :sub_agent,
            id: ctx.first.id,
            read_paths: ["preferences.md"],
            create_paths: ["research/liguria.md"]
          },
          %{
            kind: :sub_agent,
            id: ctx.second.id,
            read_paths: ["preferences.md", "research/liguria.md"],
            create_paths: ["plans/comparison.md"]
          }
        ]
    }

    put_env!(:subject_roots, [definition])
    assert {:ok, initial} = call(ctx.first, ctx, "read", %{"path" => "preferences.md"})

    params = %{
      "path" => "research/liguria.md",
      "content" =>
        "Source: controlled fixture, 2026-10-04.\nUncertainty: trains unverified.\n#{initial["revision"]}",
      "request_id" => uid("nested-create")
    }

    assert {:ok, output} = call(ctx.first, ctx, "create", params)
    assert output["receipt"]["producer"]["identity"]["id"] == ctx.first.id
    workspace = SubAgents.get(ctx.first.id).workspace
    SubAgents.forget(ctx.first.id)
    File.rm_rf!(workspace)
    SubjectDocumentBridge.reset()
    File.write!(Path.join(ctx.root, "preferences.md"), "Human update: Camogli, no car.\n")

    assert {:ok, browse} = call(ctx.second, ctx, "browse")
    assert browse["paths"] == ["preferences.md", "research/liguria.md"]
    assert {:ok, current} = call(ctx.second, ctx, "read", %{"path" => "preferences.md"})
    refute current["revision"] == initial["revision"]
    assert {:ok, research} = call(ctx.second, ctx, "read", %{"path" => "research/liguria.md"})
    assert research["content"] == params["content"]
    assert :ok = SubjectDocuments.authorize_read(ctx.second, definition.id, "research/liguria.md")

    assert {:ok, _comparison} =
             call(ctx.second, ctx, "create", %{
               "path" => "plans/comparison.md",
               "content" =>
                 "Use current #{current["revision"]} and research #{research["revision"]}",
               "request_id" => uid("nested-followup")
             })

    assert {:error, "path_or_destination_not_granted"} =
             call(ctx.second, ctx, "create", %{
               "path" => "plans/unassigned.md",
               "content" => "refuse",
               "request_id" => uid("nested-denied")
             })

    assert {:ok, outputs} = SubjectDocuments.outputs(@human, definition.id)
    assert length(outputs) == 2
    assert File.regular?(Path.join(ctx.root, "research/liguria.md"))
    assert File.regular?(Path.join(ctx.root, "plans/comparison.md"))
    refute File.exists?(Path.join(ctx.root, "plans/unassigned.md"))
  end

  test "nested proposal preserves source HEAD index and unrelated human edits", ctx do
    File.mkdir!(Path.join(ctx.root, "research"))
    File.mkdir!(Path.join(ctx.root, "plans"))
    File.write!(Path.join(ctx.root, "research/source.md"), "Initial research.\n")
    File.write!(Path.join(ctx.root, "unrelated.txt"), "Initial unrelated.\n")
    {_, 0} = System.cmd("git", ["init", "--quiet"], cd: ctx.root)
    {_, 0} = System.cmd("git", ["add", "."], cd: ctx.root)

    {_, 0} =
      System.cmd(
        "git",
        [
          "-c",
          "user.name=joshrotenberg",
          "-c",
          "user.email=joshrotenberg@gmail.com",
          "commit",
          "--quiet",
          "-m",
          "feat: record controlled subject fixture"
        ],
        cd: ctx.root
      )

    File.write!(Path.join(ctx.root, "unrelated.txt"), "Staged unrelated correction.\n")
    {_, 0} = System.cmd("git", ["add", "unrelated.txt"], cd: ctx.root)
    File.write!(Path.join(ctx.root, "unrelated.txt"), "Unstaged unrelated correction.\n")
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ctx.root)
    index = File.read!(Path.join(ctx.root, ".git/index"))
    assert {:ok, initial} = call(@human, ctx, "read", %{"path" => "research/source.md"})
    File.write!(Path.join(ctx.root, "research/source.md"), "Human source correction.\n")

    params = %{
      "path" => "research/source.md",
      "destination" => "plans/proposal.md",
      "content" => "Proposed correction.\n",
      "expected_revision" => initial["revision"],
      "request_id" => uid("nested-stale")
    }

    assert {:error, "stale_revision:" <> _current} = call(@human, ctx, "propose", params)
    assert {:ok, current} = call(@human, ctx, "read", %{"path" => "research/source.md"})

    assert {:ok, proposal} =
             call(@human, ctx, "propose", %{
               params
               | "expected_revision" => current["revision"],
                 "request_id" => uid("nested-current")
             })

    refute proposal["applied"]
    assert proposal["proposal"]["path"] == "plans/proposal.md"
    assert File.read!(Path.join(ctx.root, "research/source.md")) == "Human source correction.\n"
    assert File.read!(Path.join(ctx.root, "unrelated.txt")) == "Unstaged unrelated correction.\n"
    assert File.read!(Path.join(ctx.root, ".git/index")) == index
    assert {^head, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: ctx.root)
  end

  test "nested reads share exact grants through both production MCP protocols", ctx do
    File.mkdir!(Path.join(ctx.root, "research"))
    File.write!(Path.join(ctx.root, "research/current.md"), "Current nested working source.\n")
    File.ln_s!(tmp_workspace!(), Path.join(ctx.root, "linked"))

    definition = %{
      ctx.definition
      | grants: [%{kind: :sub_agent, id: ctx.first.id, read_paths: ["research/current.md"]}]
    }

    put_env!(:subject_roots, [definition])
    token = Identity.mint(:sub_agent, ctx.first.id)

    for protocol <- ["2025-06-18", "2026-07-28"] do
      assert {:ok, client} =
               Client.connect({:http, Custode.MCP.memory_url()},
                 protocol: protocol,
                 headers: [{"authorization", "Bearer " <> token}]
               )

      assert {:ok, %{"content" => [%{"text" => body}]}} =
               Client.call_tool(client, "subject_context", %{
                 "action" => "read",
                 "root_id" => definition.id,
                 "path" => "research/current.md"
               })

      assert Jason.decode!(body)["content"] == "Current nested working source.\n"

      for denied <- ["preferences.md", "linked/private.md", "research/../preferences.md"] do
        assert {:ok, %{"isError" => true}} =
                 Client.call_tool(client, "subject_context", %{
                   "action" => "read",
                   "root_id" => definition.id,
                   "path" => denied
                 })
      end

      assert :ok = Client.close(client)
    end

    assert {:ok, roots} = SubjectDocuments.invoke(ctx.first, %{"action" => "roots"})
    assert hd(roots["roots"])["layout"] == "bounded_recursive_markdown"
    assert hd(roots["roots"])["limits"]["path_components"] == 8

    for invalid <- [
          "../private.md",
          "research//current.md",
          "research/.hidden/current.md",
          "research/./current.md",
          "research/" <> String.duplicate("a", 200) <> ".md"
        ] do
      assert {:error, _reason} = call(@human, ctx, "read", %{"path" => invalid})

      invalid_definition = %{
        definition
        | grants: [%{kind: :sub_agent, id: ctx.first.id, read_paths: [invalid]}]
      }

      put_env!(:subject_roots, [invalid_definition])
      assert {:ok, %{"roots" => []}} = SubjectDocuments.invoke(ctx.first, %{"action" => "roots"})
    end
  end

  defp call(actor, ctx, action, args \\ %{}),
    do:
      SubjectDocuments.invoke(
        actor,
        Map.merge(%{"action" => action, "root_id" => ctx.definition.id}, args)
      )
end
