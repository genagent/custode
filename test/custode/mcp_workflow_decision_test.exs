defmodule Custode.MCPWorkflowDecisionTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo, Workflow}
  alias Custode.MCP.{CallContext, Capabilities, Identity, ToolPolicy, WorkflowDecisionTools}
  alias Custode.Workflow.{Launch, Node, Run, Stage}

  setup do
    name = uid("mcp-launch")
    repo = uid("launch-repo")
    worker = uid("launch-worker")
    caretaker = uid("launch-caretaker")

    workflow =
      Workflow.new!(name, [
        %Stage{
          name: :fixture,
          nodes: [%Node{name: :fixture, prompt: "fixture only", schema: %{}}]
        }
      ])

    put_env!(:extra_workflows, %{name => workflow})

    put_env!(
      :routines,
      for {id, role} <- [{worker, :backlog_worker}, {caretaker, :caretaker}] do
        %{
          id: id,
          role: role,
          cron: :manual,
          workspace: tmp_workspace!(),
          prompt: "fixture",
          on_note: :ignore
        }
      end
    )

    on_exit(fn ->
      run_ids = Repo.all(from(r in Run.Row, where: r.repo == ^repo, select: r.run_id))

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) in ^run_ids
        )
      )

      Repo.delete_all(from(r in Run.Row, where: r.repo == ^repo))

      Repo.delete_all(
        from(f in Feed.Entry, where: fragment("json_extract(?, '$.repo')", f.entry) == ^repo)
      )
    end)

    %{name: name, repo: repo, worker: worker, caretaker: caretaker}
  end

  test "direct handlers require verified human identity with no MCP caller fallback", ctx do
    {:ok, proposal} = Launch.propose(ctx.name, ctx.repo)

    for actor <- [
          nil,
          %{},
          %{kind: :operator, id: ""},
          %{kind: :routine, id: ctx.caretaker},
          %{kind: :routine, id: ctx.worker},
          %{kind: :sub_agent, id: uid("helper")}
        ] do
      frame = %CallContext{assigns: %{custode_identity: actor}}

      for module <- [WorkflowDecisionTools.Approve, WorkflowDecisionTools.Reject] do
        assert {:reply, %Snodo.Result{kind: :error, value: message}, ^frame} =
                 module.execute(%{proposal_id: proposal.id}, frame)

        assert message =~ "human_identity_required"
      end
    end

    assert Repo.aggregate(from(r in Run.Row, where: r.repo == ^ctx.repo), :count) == 0
    assert Enum.any?(Launch.pending(), &(&1["proposal"] == proposal.id))
    assert ToolPolicy.fetch("workflow_launch_approve") == {:ok, :operator}
    assert ToolPolicy.fetch("workflow_launch_reject") == {:ok, :operator}

    for role <- [:caretaker, :backlog_worker] do
      refute "workflow_launch_approve" in Capabilities.exposed_tool_names(role)
      refute "workflow_launch_reject" in Capabilities.exposed_tool_names(role)
    end
  end

  for protocol <- ["2025-11-25", "2026-07-28"] do
    @protocol protocol
    test "authenticated workflow decisions over HTTP #{@protocol}", ctx do
      assert Application.get_env(:custode, :oban_queues) == []
      human = Identity.mint(:operator, uid("launch-human"))
      initialize(human, @protocol)
      catalog = discover(human, @protocol)

      for module <- [WorkflowDecisionTools.Approve, WorkflowDecisionTools.Reject] do
        tool = Enum.find(catalog, &(&1["name"] == module.name()))
        assert tool
        assert tool["inputSchema"] == module.input_schema()

        assert MapSet.new(tool["outputSchema"]["required"]) ==
                 MapSet.new(module.output_schema()["required"])

        assert tool["outputSchema"]["properties"] == module.output_schema()["properties"]
      end

      {:ok, proposal} =
        Launch.propose(ctx.name, ctx.repo, budget_usd: 2.5, working_dir: "/private/fixture-only")

      approved =
        call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => proposal.id})

      assert %{"result" => %{"isError" => false, "structuredContent" => admission}} = approved
      assert admission["proposal_id"] == proposal.id
      assert admission["decision"] == "approved"
      assert admission["status"] == "running"
      assert admission["budget_usd"] == 2.5

      assert Map.keys(admission) |> Enum.sort() ==
               ~w(budget_usd decision proposal_id run_id status)

      refute Jason.encode!(approved) =~ "/private/"

      assert %{"result" => %{"structuredContent" => ^admission}} =
               call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => proposal.id})

      assert_refused(
        call(human, @protocol, "workflow_launch_reject", %{"proposal_id" => proposal.id})
      )

      assert Repo.aggregate(from(r in Run.Row, where: r.repo == ^ctx.repo), :count) == 1

      assert Repo.aggregate(
               from(j in Oban.Job,
                 where:
                   fragment("json_extract(?, '$.workflow_run')", j.meta) == ^admission["run_id"]
               ),
               :count
             ) == 1

      {:ok, rejected} = Launch.propose(ctx.name, ctx.repo)

      assert %{"result" => %{"structuredContent" => rejection}} =
               call(human, @protocol, "workflow_launch_reject", %{
                 "proposal_id" => rejected.id,
                 "reason" => "not today"
               })

      assert rejection == %{"proposal_id" => rejected.id, "decision" => "rejected"}

      assert %{"result" => %{"structuredContent" => ^rejection}} =
               call(human, @protocol, "workflow_launch_reject", %{"proposal_id" => rejected.id})

      assert_refused(
        call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => rejected.id})
      )

      for {tool, arguments} <- [
            {"workflow_launch_approve", %{}},
            {"workflow_launch_approve", %{"proposal_id" => ""}},
            {"workflow_launch_approve", %{"proposal_id" => String.duplicate("x", 161)}},
            {"workflow_launch_approve", %{"proposal_id" => proposal.id, "budget_usd" => 999}},
            {"workflow_launch_reject",
             %{"proposal_id" => rejected.id, "reason" => String.duplicate("x", 2_001)}},
            {"workflow_launch_reject", %{"proposal_id" => rejected.id, "reason" => 1}}
          ] do
        assert_invalid_arguments(human, @protocol, tool, arguments)
      end

      assert_refused(
        call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => uid("unknown")})
      )

      {:ok, omitted} = Launch.propose(ctx.name, ctx.repo)

      assert %{"result" => %{"structuredContent" => %{"decision" => "rejected"}}} =
               call(human, @protocol, "workflow_launch_reject", %{"proposal_id" => omitted.id})

      {:ok, expired} = Launch.propose(ctx.name, ctx.repo)
      cutoff = DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60)

      Repo.update_all(
        from(f in Feed.Entry,
          where: fragment("json_extract(?, '$.proposal')", f.entry) == ^expired.id
        ),
        set: [at: cutoff]
      )

      for tool <- ~w(workflow_launch_approve workflow_launch_reject) do
        response = call(human, @protocol, tool, %{"proposal_id" => expired.id})
        assert_code(response, "expired_proposal")
      end

      {:ok, invalid} = Launch.propose(ctx.name, ctx.repo)
      definition = Application.fetch_env!(:custode, :extra_workflows)[ctx.name]
      Application.put_env(:custode, :extra_workflows, %{ctx.name => %{definition | stages: []}})

      assert_code(
        call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => invalid.id}),
        "admission_failed"
      )

      Application.put_env(:custode, :extra_workflows, %{})

      assert_code(
        call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => invalid.id}),
        "unknown_workflow"
      )

      Application.put_env(:custode, :extra_workflows, %{ctx.name => definition})

      # Corrupt only this fixture's saved context to force an exception before admission.
      private = "/private/fixture-secret"

      Repo.query!(
        "UPDATE feed_entries SET entry = json_set(entry, '$.launch_opts.context', ?) WHERE json_extract(entry, '$.proposal') = ?",
        [private, invalid.id]
      )

      refused = call(human, @protocol, "workflow_launch_approve", %{"proposal_id" => invalid.id})
      assert_code(refused, "admission_failed")
      refute Jason.encode!(refused) =~ private
      refute Jason.encode!(refused) =~ "Protocol.UndefinedError"
      assert Enum.any?(Launch.pending(), &(&1["proposal"] == invalid.id))

      {:ok, pending} = Launch.propose(ctx.name, ctx.repo)
      before = Repo.aggregate(Feed.Entry, :count)

      for id <- [ctx.worker, ctx.caretaker] do
        token = Identity.mint(:routine, id)
        initialize(token, @protocol)
        names = Enum.map(discover(token, @protocol), & &1["name"])
        refute "workflow_launch_approve" in names
        refute "workflow_launch_reject" in names

        for tool <- ~w(workflow_launch_approve workflow_launch_reject) do
          assert_refused(call(token, @protocol, tool, %{"proposal_id" => pending.id}))
        end
      end

      helper = Identity.mint(:sub_agent, uid("launch-helper"))

      for token <- [helper, nil], tool <- ~w(workflow_launch_approve workflow_launch_reject) do
        response =
          post(token, @protocol, "tools/call", %{
            "name" => tool,
            "arguments" => %{"proposal_id" => pending.id}
          })

        assert response.status in [401, 403]
      end

      assert Repo.aggregate(Feed.Entry, :count) == before
      assert Enum.any?(Launch.pending(), &(&1["proposal"] == pending.id))
    end
  end

  defp initialize(token, protocol) do
    if protocol == "2025-11-25" do
      response =
        post(token, nil, "initialize", %{
          "protocolVersion" => protocol,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "workflow-fixture", "version" => "1"}
        })

      assert response.status == 200
      assert response.body["result"]["protocolVersion"] == protocol
    end
  end

  defp discover(token, protocol, params \\ %{}) do
    response = post(token, protocol, "tools/list", params)
    assert response.status == 200
    page = response.body["result"]

    case page["nextCursor"] do
      nil -> page["tools"]
      cursor -> page["tools"] ++ discover(token, protocol, %{"cursor" => cursor})
    end
  end

  defp call(token, protocol, name, args) do
    response = post(token, protocol, "tools/call", %{"name" => name, "arguments" => args})
    assert response.status == 200
    response.body
  end

  defp assert_invalid_arguments(token, protocol, name, args) when map_size(args) == 0 do
    response = post(token, protocol, "tools/call", %{"name" => name, "arguments" => args})
    assert response.status == 200

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} =
             response.body

    assert message == "Missing required arguments: proposal_id"
  end

  defp assert_invalid_arguments(token, protocol, name, args) do
    response = post(token, protocol, "tools/call", %{"name" => name, "arguments" => args})
    expected_status = if protocol == "2026-07-28", do: 400, else: 200
    assert response.status == expected_status
    assert %{"error" => %{"code" => -32_602}} = response.body
  end

  defp assert_code(response, code) do
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} = response
    assert message == "workflow launch decision refused: " <> code
  end

  defp assert_refused(%{"error" => _error}), do: :ok
  defp assert_refused(%{"result" => %{"isError" => true}}), do: :ok

  defp post(token, protocol, method, params) do
    headers = [{"accept", "application/json, text/event-stream"}]
    headers = if token, do: [{"authorization", "Bearer " <> token} | headers], else: headers
    headers = if protocol, do: [{"mcp-protocol-version", protocol} | headers], else: headers

    {headers, params} = modern_request(protocol, method, headers, params)

    Req.post!(Custode.MCP.url(),
      json: %{
        "jsonrpc" => "2.0",
        "id" => System.unique_integer([:positive]),
        "method" => method,
        "params" => params
      },
      headers: headers,
      retry: false,
      receive_timeout: 10_000
    )
  end

  defp modern_request("2026-07-28" = protocol, method, headers, params) do
    headers = [{"mcp-method", method} | headers]

    headers =
      if method == "tools/call", do: [{"mcp-name", params["name"]} | headers], else: headers

    params =
      Map.put(params, "_meta", %{
        "io.modelcontextprotocol/protocolVersion" => protocol,
        "io.modelcontextprotocol/clientCapabilities" => %{}
      })

    {headers, params}
  end

  defp modern_request(_protocol, _method, headers, params), do: {headers, params}
end
