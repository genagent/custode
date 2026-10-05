defmodule Custode.SubjectAssignmentsTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias Custode.MCP.{CallContext, Capabilities, Identity, SubjectDocumentTools, Tools}
  alias Custode.SubjectAssignments.{Assignment, Launch}
  alias Snodo.Client

  alias Custode.{
    ContextReceipts,
    OperatorMessages,
    Repo,
    SubAgents,
    SubjectAssignmentLaunch,
    SubjectAssignments,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  @endpoint CustodeWeb.Endpoint
  @human %{kind: :operator, id: "assignment-human"}

  setup do
    parent = routine_fixture!(tmp_workspace!())
    helper_id = uid("assigned-helper")
    SubAgents.record_spawn!(helper_id, parent.id, %{workspace: tmp_workspace!()})
    ordinary = Identity.mint(:sub_agent, helper_id)
    root = tmp_workspace!()
    File.write!(Path.join(root, "preferences.md"), "No car; stay near a train station.\n")
    File.write!(Path.join(root, "private.md"), "Unadmitted content")
    definition = %{id: uid("assignment-root"), path: root, subject: "Travel", grants: []}
    put_env!(:subject_roots, [definition])
    config_dir = tmp_workspace!()
    put_env!(:mcp_config_dir, config_dir)

    on_exit(fn ->
      for launch <- Repo.all(Launch), do: Identity.revoke_assignment(launch.launch_id)
      Repo.delete_all(Launch)
      Repo.delete_all(Assignment)

      Repo.delete_all(
        from(job in Oban.Job,
          where: fragment("json_extract(?, '$.agent_id')", job.meta) == ^helper_id
        )
      )

      Repo.delete_all(from(row in ContextReceipts.Row, where: row.root_id == ^definition.id))

      Repo.delete_all(
        from(row in Custode.RunContextReceipts.Row, where: row.agent_id == ^helper_id)
      )

      SubjectDocumentBridge.reset()
      SubAgents.forget(helper_id)
    end)

    %{
      parent: parent,
      helper_id: helper_id,
      ordinary: ordinary,
      definition: definition,
      root: root,
      config_dir: config_dir
    }
  end

  test "operator admits an immutable one-use assignment, ordinary helper gains no authority",
       ctx do
    params = admission(ctx)
    assert {:ok, receipt} = SubjectAssignments.invoke(@human, params)
    assert receipt["status"] == "admitted"
    assert receipt["launch_id"] == nil
    assert receipt["helper_epoch"]["record_id"]
    assert receipt["parent_execution_binding"] =~ "unknown"
    assert {:ok, ^receipt} = SubjectAssignments.invoke(@human, params)

    assert {:error, "idempotency_conflict"} =
             SubjectAssignments.invoke(@human, Map.put(params, "destination", "different.md"))

    assert {:error, "root_not_granted"} = read(%{kind: :sub_agent, id: ctx.helper_id}, ctx)
    assert {:ok, ctx.ordinary} == Identity.token(:sub_agent, ctx.helper_id)

    assert {:error, "helper_has_pending_assignment"} =
             SubjectAssignments.invoke(@human, admission(ctx))
  end

  test "parents, helpers and unauthenticated calls cannot admit or revoke", ctx do
    for actor <- [
          nil,
          %{kind: :routine, id: ctx.parent.id},
          %{kind: :sub_agent, id: ctx.helper_id}
        ] do
      assert {:error, "operator_assignment_admission_required"} =
               SubjectAssignments.invoke(actor, admission(ctx))
    end

    assert {:error, _} =
             SubjectAssignments.invoke(
               @human,
               Map.put(admission(ctx), "parent_execution", %{"job_id" => 1})
             )

    assert {:error, _} =
             SubjectAssignments.invoke(
               @human,
               Map.put(admission(ctx), "read_paths", ["../private.md"])
             )

    assert {:error, _} =
             SubjectAssignments.invoke(@human, Map.put(admission(ctx), "destination", "./old.md"))
  end

  test "persisted turn credential has only exact subject reads and create destination", ctx do
    {job, launch, actor, token} = bound(ctx)
    assert Identity.verify(token) == {:ok, actor}
    assert Identity.token(:sub_agent, ctx.helper_id) == {:ok, ctx.ordinary}
    assert Capabilities.authorize_endpoint(:memory, actor) == :ok
    assert {:error, _} = Capabilities.authorize_endpoint(:main, actor)
    assert Capabilities.authorized_tool_names(:memory, actor) == ["subject_context"]
    assert job.args["strict_mcp_config"] == true
    assert job.args["hermetic"] == true
    assert job.args["allowed_tools"] == ["mcp__subject__subject_context"]
    assert {:ok, document} = read(actor, ctx)
    assert document["content"] =~ "No car"
    assert {:error, "path_or_destination_not_granted"} = read(actor, ctx, "private.md")
    assert {:error, _} = create(actor, ctx, "preferences.md", "overwrite")
    assert {:error, _} = create(actor, ctx, "other.md", "outside destination")

    assert {:error, _} =
             SubjectDocuments.invoke(actor, %{
               "action" => "propose",
               "root_id" => ctx.definition.id,
               "path" => "preferences.md",
               "destination" => "result.md",
               "expected_revision" => document["revision"],
               "content" => "apply",
               "request_id" => uid("proposal")
             })

    assert {:ok, output} = create(actor, ctx, "result.md", "Retained research")
    proof = output["receipt"]["producer"]["assignment_execution"]
    assert proof["execution"]["job_id"] == job.id
    assert proof["execution"]["agent_turn_id"] == job.meta["agent_turn_id"]
    assert proof["launch_id"] == launch.launch_id
    assert proof["admission_message_id"]
    assert proof["grant_revision"] == output["receipt"]["grant_revision"]

    assert proof["grant_revision"] ==
             Repo.get!(Assignment, launch.assignment_id).record["grant_revision"]

    refute Jason.encode!(proof) =~ token
    assert File.read!(Path.join(ctx.root, "preferences.md")) =~ "No car"
    assert {:error, _} = create(actor, ctx, "result.md", "replace")
  end

  test "retrieval receipt binds exact host job while model use and hidden context remain unknown",
       ctx do
    {job, launch, actor, token} = bound(ctx)
    id = uid("assignment-retrieval")
    frame = %CallContext{assigns: %{custode_identity: actor, custode_delivery_id: id}}

    result =
      tool_json(
        SubjectDocumentTools.Context.execute(
          %{action: "read", root_id: ctx.definition.id, path: "preferences.md"},
          frame
        )
      )

    assert result["context_receipt_id"] == id
    row = Repo.get!(ContextReceipts.Row, id)
    assert row.record["execution_binding"] == "host_launch_credential_exact_job_not_model_use"
    assert row.record["assignment_execution"]["execution"]["job_id"] == job.id
    assert row.record["assignment_execution"]["launch_id"] == launch.launch_id
    assert row.record["model_received"] == "unknown"
    assert row.record["native_hidden_context"] == "unknown"
    refute Jason.encode!(row.record) =~ token
    refute row.payload =~ token
  end

  test "queued, terminal, retried, snoozed and altered job identities cannot authorize", ctx do
    {job, _launch, actor, _token} = bound(ctx)

    for changes <- [
          [state: "available"],
          [state: "completed"],
          [state: "retryable"],
          [attempt: 2],
          [max_attempts: 2],
          [meta: Map.put(job.meta, "snoozed", 1)],
          [meta: Map.put(job.meta, "agent_turn_id", "other")],
          [meta: Map.put(job.meta, "agent_generation", "other")],
          [meta: Map.put(job.meta, "correlation_id", "other")],
          [meta: Map.put(job.meta, "config_revision", "other")],
          [args: Map.put(job.args, "prompt", "other")]
        ] do
      Repo.update!(Ecto.Changeset.change(job, changes))
      assert {:error, "assignment_execution_unavailable"} = read(actor, ctx)

      Repo.update!(
        Ecto.Changeset.change(
          Repo.get!(Oban.Job, job.id),
          Map.take(Map.from_struct(job), Keyword.keys(changes))
        )
      )
    end

    assert {:ok, _} = read(actor, ctx)
  end

  test "revoke removes credential/config and preserves immutable output producer", ctx do
    {_job, launch, actor, token} = bound(ctx)
    assert {:ok, output} = create(actor, ctx, "result.md", "Keep after cleanup")

    assert {:ok, %{"status" => "revoked"}} =
             SubjectAssignments.invoke(@human, %{
               "action" => "revoke",
               "assignment_id" => launch.assignment_id
             })

    assert Identity.verify(token) == :error
    refute File.exists?(launch.config_path)
    assert File.read!(Path.join(ctx.root, "result.md")) == "Keep after cleanup"

    assert {:ok, retained} =
             SubjectDocuments.invoke(@human, %{
               "action" => "receipt",
               "root_id" => ctx.definition.id,
               "request_id" => output["receipt"]["request_id"]
             })

    assert retained["producer"] == output["receipt"]["producer"]
    assert {:error, _} = read(actor, ctx)
  end

  test "expiration and root revision changes fail closed", ctx do
    {_job, launch, actor, token} = bound(ctx)
    row = Repo.get!(Assignment, launch.assignment_id)

    Repo.update!(
      Ecto.Changeset.change(row, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
    )

    assert {:error, _} = read(actor, ctx)
    SubjectAssignments.cleanup()
    assert Identity.verify(token) == :error
    expired = Repo.get!(Assignment, row.assignment_id)
    Repo.update!(Ecto.Changeset.change(expired, expires_at: row.expires_at))
    assert :ok = SubjectAssignments.authorize(actor)
    put_env!(:subject_roots, [%{ctx.definition | subject: "Changed subject"}])
    assert {:error, _} = read(actor, ctx)
  end

  test "reused helper id cannot retarget the admitted epoch", ctx do
    {_job, _launch, actor, _token} = bound(ctx)
    SubAgents.forget(ctx.helper_id)
    SubAgents.record_spawn!(ctx.helper_id, ctx.parent.id, %{workspace: tmp_workspace!()})
    assert {:error, _} = read(actor, ctx)
  end

  test "terminal adapter event revokes credential before persistent job settlement", ctx do
    {job, launch, actor, token} = bound(ctx)
    SubjectAssignments.handle_event([:oban_claude, :run, :stop], %{}, %{job: job}, nil)
    assert Identity.verify(token) == :error
    refute File.exists?(launch.config_path)
    assert Repo.get!(Oban.Job, job.id).state == "executing"
    assert {:error, _} = read(actor, ctx)
    assert Repo.get!(Launch, launch.launch_id).settled
  end

  test "one admission cannot bind a second turn", ctx do
    {job, launch, _actor, _token} = bound(ctx)
    assert SubjectAssignments.pending(ctx.helper_id) == nil

    ordinary_args = %{"prompt" => "next", "host_capture" => %{nested: true}}

    assert {:ok, ordinary_job} =
             SubjectAssignmentLaunch.enqueue(
               ctx.helper_id,
               job.meta["config_revision"],
               ordinary_args,
               Map.put(job.meta, "agent_turn_id", uid("next-turn"))
             )

    assert ordinary_job.args == ordinary_args
    refute ordinary_job.args["mcp_config"]
    assert Repo.aggregate(Launch, :count) == 1
    assert Repo.get!(Assignment, launch.assignment_id).status == "bound"
  end

  test "no durable matching delivery means no job, credential or private config survives", ctx do
    assert {:ok, _} = SubjectAssignments.invoke(@human, admission(ctx))
    meta = metadata(ctx)
    before_count = Repo.aggregate(Oban.Job, :count)

    assert {:error, :subject_assignment_enqueue_refused} =
             SubjectAssignmentLaunch.enqueue(
               ctx.helper_id,
               meta["config_revision"],
               %{"prompt" => "unadmitted"},
               meta
             )

    assert Repo.aggregate(Oban.Job, :count) == before_count
    assert Repo.aggregate(Launch, :count) == 0
    assert Path.wildcard(Path.join(ctx.config_dir, "subject-launches/*.json")) == []
    assert Identity.token(:sub_agent, ctx.helper_id) == {:ok, ctx.ordinary}
  end

  test "private launch config permissions and cleanup path validation", ctx do
    {_job, launch, _actor, _token} = bound(ctx)
    assert {:ok, %{mode: mode}} = File.stat(launch.config_path)
    assert Bitwise.band(mode, 0o777) == 0o600
    unrelated = Path.join(ctx.root, "private.md")
    SubjectAssignmentLaunch.remove_config(%{launch | config_path: unrelated})
    assert File.read!(unrelated) == "Unadmitted content"
  end

  test "real start_agent launch installs the host wrapper and binds generated turn identity",
       ctx do
    frame = %CallContext{assigns: %{custode_identity: %{kind: :routine, id: ctx.parent.id}}}

    started =
      tool_json(
        Tools.StartAgent.execute(
          %{agent_id: ctx.helper_id, workspace: tmp_workspace!()},
          frame
        )
      )

    assert started["state"] == "idle"
    on_exit(fn -> Custode.Agents.stop_agent(ctx.helper_id) end)
    assert {:ok, _} = SubjectAssignments.invoke(@human, admission(ctx))
    prompt = "Read preferences and retain research"

    assert {:ok, message, :created} =
             OperatorMessages.submit(
               ctx.helper_id,
               prompt,
               [
                 actor: %{kind: :routine, id: ctx.parent.id},
                 idempotency_key: uid("real-delivery")
               ],
               fn message ->
                 assert :processing =
                          Custode.Agents.submit_prompt(ctx.helper_id, prompt,
                            correlation_id: message.provider_correlation_id
                          )

                 {:ok, :delivered}
               end
             )

    launch = Repo.one!(Launch)
    job = Repo.get!(Oban.Job, launch.job_id)
    assert job.state == "available"
    assert job.meta["agent_generation"]
    assert job.meta["agent_turn_id"]
    assert job.meta["correlation_id"] == message.provider_correlation_id
    assert launch.record["execution"]["agent_turn_id"] == job.meta["agent_turn_id"]
    assert {:ok, info} = Custode.Agents.info(ctx.helper_id)
    assert info.config_revision == job.meta["config_revision"]
    assert launch.record["admission_message_id"] == message.message_id
    assert job.args["mcp_config"] == [launch.config_path]
    assert job.args["allowed_tools"] == ["mcp__subject__subject_context"]
    refute File.exists?(Path.join(ctx.root, "result.md"))
  end

  test "HTTP discovery and frozen server-emitted retrievals retain the exact launch", ctx do
    {_job, launch, _actor, token} = bound(ctx)

    assert {:ok, client} =
             Client.connect({:http, Custode.MCP.memory_url()},
               headers: [{"authorization", "Bearer " <> token}]
             )

    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.map(tools, & &1["name"]) == ["subject_context"]

    assert {:ok, %{"content" => [%{"text" => text}]}} =
             Client.call_tool(client, "subject_context", %{
               "action" => "read",
               "root_id" => ctx.definition.id,
               "path" => "preferences.md"
             })

    payload = Jason.decode!(text)

    eventually(fn ->
      Repo.get!(ContextReceipts.Row, payload["context_receipt_id"]).record["state"] ==
        "server_emitted"
    end)

    row = Repo.get!(ContextReceipts.Row, payload["context_receipt_id"])
    assert row.record["state"] == "server_emitted"
    assert row.record["assignment_execution"]["launch_id"] == launch.launch_id
    assert row.payload == text
    assert row.record["model_received"] == "unknown"
    assert :ok = Client.close(client)
  end

  test "adapter detail links exact retained retrievals after producer cleanup and human edits",
       ctx do
    {job, launch, actor, token} = bound(ctx)

    assert {:ok, adapter} =
             Custode.RunContextReceipts.capture(:oban_claude, %{args: job.args, job: job})

    assert adapter["document_tool_binding"] ==
             "host_assignment_credential_available_at_adapter_entry"

    assert adapter["document_retrievals"]["receipts"] == []

    frame = %CallContext{
      assigns: %{custode_identity: actor, custode_delivery_id: uid("linked-read")}
    }

    read_payload =
      tool_json(
        SubjectDocumentTools.Context.execute(
          %{action: "read", root_id: ctx.definition.id, path: "preferences.md"},
          frame
        )
      )

    assert {:ok, current_adapter} = Custode.RunContextReceipts.read(@human, adapter["receipt_id"])
    assert [reference] = current_adapter["document_retrievals"]["receipts"]
    assert reference["receipt_id"] == read_payload["context_receipt_id"]
    assert reference["state"] == "prepared"

    assert {:ok, view, _html} =
             live(
               build_conn(),
               "/contexts/" <>
                 URI.encode_www_form(ctx.helper_id) <> "?receipt=" <> adapter["receipt_id"]
             )

    assert has_element?(
             view,
             "#run-context-documents a[href='/subjects/#{ctx.definition.id}?receipt=#{reference["receipt_id"]}']"
           )

    assert render(view) =~ "model receipt and use remain unknown"

    refute Jason.encode!(current_adapter) =~ token
    refute Jason.encode!(current_adapter) =~ launch.config_path
    assert {:ok, _} = create(actor, ctx, "result.md", "Retained research from producer")
    SubjectAssignments.handle_event([:oban_claude, :run, :stop], %{}, %{job: job}, nil)
    SubAgents.forget(ctx.helper_id)
    Repo.delete!(job)
    File.write!(Path.join(ctx.root, "preferences.md"), "Prefer Camogli; latest human edit.\n")

    assert {:ok, retained_adapter} =
             Custode.RunContextReceipts.read(@human, adapter["receipt_id"])

    assert retained_adapter["document_retrievals"] == current_adapter["document_retrievals"]
    assert {:ok, retained} = ContextReceipts.read(@human, reference["receipt_id"])
    assert Jason.decode!(retained["exact_tool_text"])["content"] =~ "No car"
    assert File.read!(Path.join(ctx.root, "result.md")) == "Retained research from producer"
    assert {:ok, current} = read(@human, ctx)
    assert current["content"] =~ "latest human edit"
    refute current["revision"] == reference["revision"]
    # A fresh worker is a distinct recorded epoch and exact host turn, not a model-use claim.
    SubAgents.record_spawn!(ctx.helper_id, ctx.parent.id, %{workspace: tmp_workspace!()})

    {_next_job, next_launch, next_actor, _next_token} =
      bound(ctx, %{
        "destination" => "follow-up.md",
        "read_paths" => ["preferences.md", "result.md", "follow-up.md"]
      })

    refute next_launch.launch_id == launch.launch_id
    assert {:ok, next_preferences} = read(next_actor, ctx)
    assert next_preferences["revision"] == current["revision"]
    assert {:ok, previous_output} = read(next_actor, ctx, "result.md")
    assert previous_output["content"] == "Retained research from producer"

    assert {:ok, _} =
             create(
               next_actor,
               ctx,
               "follow-up.md",
               "Follow-up using the latest human preferences and retained research"
             )

    assert File.read!(Path.join(ctx.root, "result.md")) == "Retained research from producer"

    assert {:ok, detail} =
             Custode.ReturnViews.invoke(@human, %{
               "action" => "detail",
               "root_id" => ctx.definition.id,
               "path" => "result.md"
             })

    assert [production] = detail["navigation"]["productions"]
    assert production["recorded_owner"]["id"] == ctx.parent.id
    assert production["helper"]["reference"] == adapter["assignment_execution"]["helper_epoch"]
    assert production["helper"]["record"]["registry_state"] == "removed"
    assert production["producing_context"]["receipt_id"] == adapter["receipt_id"]
    assert production["producing_context"]["native_context_receipt_and_use"] == "unknown"

    assert {:ok, output_view, _} =
             live(build_conn(), "/subjects/#{ctx.definition.id}?file=result.md")

    assert has_element?(
             output_view,
             "#document-return-navigation a[href='#{production["producing_context"]["link"]}']",
             "Open captured run context"
           )

    definition =
      Map.put(ctx.definition, :grants, [%{kind: :routine, id: ctx.parent.id, read_paths: "all"}])

    put_env!(:subject_roots, [definition])

    assert {:ok, parent_detail} =
             Custode.ReturnViews.invoke(%{kind: :routine, id: ctx.parent.id}, %{
               "action" => "detail",
               "root_id" => definition.id,
               "path" => "result.md"
             })

    assert [parent_production] = parent_detail["navigation"]["productions"]
    assert parent_production["producing_context"] == %{"availability" => "operator_required"}
    refute Jason.encode!(parent_production) =~ adapter["receipt_id"]
    assert parent_production["helper"]["reference"] == production["helper"]["reference"]

    assert {:ok, outputs} = SubjectDocuments.outputs(@human, definition.id)
    receipt = Enum.find(outputs, &(&1["request"]["path"] == "result.md"))

    for conflicting <- [
          put_in(receipt, ["producer", "assignment_execution", "root_id"], "another-root"),
          put_in(receipt, ["producer", "parent"], "another-parent"),
          put_in(receipt, ["producer", "identity", "subject_launch_id"], "another-launch")
        ] do
      navigation =
        Custode.ReturnNavigation.read(@human, definition.id, detail["revision"], [conflicting])

      assert [refused] = navigation["productions"]
      refute refused["recorded_owner"]["link"]
      refute refused["producing_context"]["link"]
      assert refused["helper"]["availability"] == "conflicting_provenance"
    end
  end

  test "historical context and document links survive newer unrelated receipts without broadening authority",
       ctx do
    {job, _launch, actor, _token} = bound(ctx)

    assert {:ok, adapter} =
             Custode.RunContextReceipts.capture(:oban_claude, %{args: job.args, job: job})

    frame = %CallContext{
      assigns: %{custode_identity: actor, custode_delivery_id: uid("old-retrieval")}
    }

    payload =
      tool_json(
        SubjectDocumentTools.Context.execute(
          %{action: "read", root_id: ctx.definition.id, path: "preferences.md"},
          frame
        )
      )

    original = Repo.get!(ContextReceipts.Row, payload["context_receipt_id"])
    run_row = Repo.get!(Custode.RunContextReceipts.Row, adapter["receipt_id"])

    for n <- 1..101 do
      Repo.insert!(%ContextReceipts.Row{
        original
        | receipt_id: uid("unrelated-retrieval"),
          record:
            put_in(original.record, ["assignment_execution", "launch_id"], uid("other-launch")),
          payload: nil,
          at: DateTime.add(original.at, n, :second)
      })

      Repo.insert!(%Custode.RunContextReceipts.Row{
        run_row
        | receipt_id: uid("newer-context"),
          record: Map.put(run_row.record, "assignment_execution", nil),
          payload: nil,
          at: DateTime.add(run_row.at, n, :second)
      })
    end

    binding = adapter["assignment_execution"]

    for changed_execution <- [
          Map.put(
            original.record["assignment_execution"]["execution"],
            "agent_turn_id",
            "other-turn"
          ),
          Map.put(original.record["assignment_execution"]["execution"], "unexpected", true),
          Map.delete(original.record["assignment_execution"]["execution"], "correlation_id")
        ] do
      Repo.insert!(%ContextReceipts.Row{
        original
        | receipt_id: uid("wrong-execution"),
          record:
            put_in(original.record, ["assignment_execution", "execution"], changed_execution),
          payload: nil,
          at: DateTime.add(original.at, 200, :second)
      })
    end

    assert [found] = SubjectAssignments.retrievals(binding)["receipts"]
    assert found["receipt_id"] == original.receipt_id
    refute SubjectAssignments.retrievals(binding)["has_more"]

    assert Custode.RunContextReceipts.assignment_reference(@human, binding)["receipt_id"] ==
             adapter["receipt_id"]

    refute Custode.RunContextReceipts.assignment_reference(
             @human,
             put_in(binding, ["execution", "agent_turn_id"], "other-turn")
           )["link"]

    assert length(elem(Custode.RunContextReceipts.list(@human, ctx.helper_id), 1)) == 100

    jobs_before_navigation = Repo.aggregate(Oban.Job, :count)

    assert {:ok, run_view, _} =
             live(build_conn(), "/contexts/#{ctx.helper_id}?receipt=#{adapter["receipt_id"]}")

    assert has_element?(run_view, "#run-context-detail")

    assert {:ok, document_view, _} =
             live(build_conn(), "/subjects/#{ctx.definition.id}?receipt=#{original.receipt_id}")

    assert has_element?(document_view, "#context-receipt")
    another = %{ctx.definition | id: uid("different-root"), path: tmp_workspace!()}
    put_env!(:subject_roots, [ctx.definition, another])

    assert {:ok, _wrong_view, wrong} =
             live(build_conn(), "/subjects/#{another.id}?receipt=#{original.receipt_id}")

    assert wrong =~ "Receipt belongs to another subject root"
    refute wrong =~ "No car; stay near"

    assert Repo.aggregate(Oban.Job, :count) == jobs_before_navigation

    for _ <- 1..20,
        do:
          Repo.insert!(%ContextReceipts.Row{
            original
            | receipt_id: uid("same-launch-retrieval"),
              payload: nil
          })

    assert length(SubjectAssignments.retrievals(binding)["receipts"]) == 20
    assert SubjectAssignments.retrievals(binding)["has_more"]
    Repo.update!(Ecto.Changeset.change(run_row, payload: nil))

    assert Custode.RunContextReceipts.assignment_reference(@human, binding)["payload_state"] ==
             "retired"

    Repo.update!(Ecto.Changeset.change(run_row, at: DateTime.add(run_row.at, -8, :day)))

    assert Custode.RunContextReceipts.assignment_reference(@human, binding)["payload_state"] ==
             "expired"

    Repo.update!(
      Ecto.Changeset.change(run_row,
        record: put_in(run_row.record, ["execution", "agent_turn_id"], "wrong-outer-turn")
      )
    )

    refute Custode.RunContextReceipts.assignment_reference(@human, binding)["link"]

    Repo.update!(
      Ecto.Changeset.change(Repo.get!(Custode.RunContextReceipts.Row, run_row.receipt_id),
        record: run_row.record
      )
    )

    second_id =
      "rc-" <>
        (:crypto.hash(
           :sha256,
           :erlang.term_to_binary({:oban_claude, job.id, job.attempt, 0}, [:deterministic])
         )
         |> Base.encode16(case: :lower))

    refute second_id == run_row.receipt_id
    Repo.insert!(%Custode.RunContextReceipts.Row{run_row | receipt_id: second_id})
    refute Custode.RunContextReceipts.assignment_reference(@human, binding)["link"]
  end

  test "scoped arguments freeze JSON identity without mutating the original host capture", ctx do
    original = %{
      "custode_integration_capture" => %{
        entries: [%{name: "controlled", enabled: true, optional: nil}],
        revision: "fixture-revision"
      }
    }

    {job, launch, actor, _token} = bound(ctx, %{}, original)

    assert original["custode_integration_capture"].entries == [
             %{name: "controlled", enabled: true, optional: nil}
           ]

    refute Map.has_key?(original, "mcp_config")

    assert job.args["custode_integration_capture"]["entries"] == [
             %{"name" => "controlled", "enabled" => true, "optional" => nil}
           ]

    assert launch.record["arguments_sha256"] == SubjectDocuments.digest(job.args)
    assert {:ok, _} = read(actor, ctx)
  end

  test "nonJSON and colliding scoped arguments refuse before job or credential retention", ctx do
    assert {:ok, _} = SubjectAssignments.invoke(@human, admission(ctx))
    prompt = "Controlled JSON validation"

    assert {:ok, message, :created} =
             OperatorMessages.submit(
               ctx.helper_id,
               prompt,
               [actor: @human, idempotency_key: uid("json-delivery")],
               fn _message -> {:ok, :queued} end
             )

    meta = Map.put(metadata(ctx), "correlation_id", message.provider_correlation_id)
    count = Repo.aggregate(Oban.Job, :count)

    invalid_args =
      Enum.map(
        [
          self(),
          {:tuple, 1},
          :unsupported,
          DateTime.utc_now(),
          %{:key => 1, "key" => 2},
          %{nil => 1, "nil" => 2},
          %{1 => "invalid key"}
        ],
        &%{"prompt" => prompt, "host_capture" => %{nested: [&1]}}
      ) ++
        [
          %{"prompt" => prompt, "mcp_config" => self()},
          %{:prompt => prompt, "prompt" => prompt}
        ]

    for args <- invalid_args do
      assert {:error, :subject_assignment_enqueue_refused} =
               SubjectAssignmentLaunch.enqueue(ctx.helper_id, meta["config_revision"], args, meta)

      assert Repo.aggregate(Oban.Job, :count) == count
      assert Repo.aggregate(Launch, :count) == 0
      assert Path.wildcard(Path.join(ctx.config_dir, "subject-launches/*.json")) == []
      assert {:ok, ctx.ordinary} == Identity.token(:sub_agent, ctx.helper_id)
    end

    assert {:ok, job} =
             SubjectAssignmentLaunch.enqueue(
               ctx.helper_id,
               meta["config_revision"],
               %{"prompt" => prompt, "host_capture" => %{nested: [nil, true, 1, 2.5, "ok"]}},
               meta
             )

    assert Repo.get!(Oban.Job, job.id).args["host_capture"]["nested"] == [nil, true, 1, 2.5, "ok"]
  end

  test "expected root revision and helper record fence admission before any grant exists", ctx do
    params = admission(ctx)

    assert {:error, "assignment_admission_unavailable"} =
             SubjectAssignments.invoke(
               @human,
               Map.put(params, "expected_root_revision", String.duplicate("0", 64))
             )

    assert {:error, "assignment_admission_unavailable"} =
             SubjectAssignments.invoke(
               @human,
               Map.put(
                 params,
                 "expected_helper_record_id",
                 params["expected_helper_record_id"] + 1
               )
             )

    assert {:ok, roots} = SubjectDocuments.invoke(@human, %{"action" => "roots"})
    assert hd(roots["roots"])["configuration_revision"] == params["expected_root_revision"]
    assert Repo.aggregate(Assignment, :count) == 0
  end

  defp admission(ctx) do
    %{
      "action" => "admit",
      "assignment_id" => uid("assignment"),
      "helper_id" => ctx.helper_id,
      "root_id" => ctx.definition.id,
      "expected_root_revision" => SubjectDocuments.digest(ctx.definition),
      "expected_helper_record_id" => helper_record_id(ctx.helper_id),
      "read_paths" => ["preferences.md", "result.md"],
      "destination" => "result.md",
      "expires_in_seconds" => 600
    }
  end

  defp helper_record_id(id) do
    {:ok, reference} = Custode.HelperRecords.publication_reference(id)
    reference.helper_epoch.record_id
  end

  defp metadata(ctx) do
    %{
      "agent_id" => ctx.helper_id,
      "agent_generation" => uid("generation"),
      "agent_turn_id" => uid("turn"),
      "arc_id" => "default",
      "config_revision" => uid("configuration"),
      "correlation_id" => uid("correlation")
    }
  end

  defp bound(ctx, overrides \\ %{}, extra_args \\ %{}) do
    assert {:ok, _} = SubjectAssignments.invoke(@human, Map.merge(admission(ctx), overrides))
    meta = metadata(ctx)
    prompt = "Research using current preferences"

    assert {:ok, message, :created} =
             OperatorMessages.submit(
               ctx.helper_id,
               prompt,
               [actor: @human, idempotency_key: uid("delivery")],
               fn _message -> {:ok, :queued} end
             )

    meta = Map.put(meta, "correlation_id", message.provider_correlation_id)

    assert {:ok, queued} =
             SubjectAssignmentLaunch.enqueue(
               ctx.helper_id,
               meta["config_revision"],
               Map.merge(%{"prompt" => prompt}, extra_args),
               meta
             )

    job = Repo.update!(Ecto.Changeset.change(queued, state: "executing", attempt: 1))
    launch = Repo.get_by!(Launch, job_id: job.id)

    token =
      File.read!(launch.config_path)
      |> Jason.decode!()
      |> get_in(["mcpServers", "subject", "headers", "Authorization"])
      |> String.replace_prefix("Bearer ", "")

    assert {:ok, actor} = Identity.verify(token)
    {job, launch, actor, token}
  end

  defp read(actor, ctx, path \\ "preferences.md"),
    do:
      SubjectDocuments.invoke(actor, %{
        "action" => "read",
        "root_id" => ctx.definition.id,
        "path" => path
      })

  defp create(actor, ctx, path, content),
    do:
      SubjectDocuments.invoke(actor, %{
        "action" => "create",
        "root_id" => ctx.definition.id,
        "path" => path,
        "content" => content,
        "request_id" => uid("assignment-output")
      })
end
