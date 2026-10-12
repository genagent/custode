defmodule Custode.MCPWorkflowBudgetTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo, Workflow}
  alias Custode.MCP.{CallContext, Capabilities, Identity, ToolPolicy, WorkflowBudgetTools}
  alias Custode.Workflow.{Node, Run, Stage}

  @tool "workflow_budget_resume"

  setup do
    name = uid("mcp-budget")
    repo = uid("budget-repo")
    worker = uid("budget-worker")
    caretaker = uid("budget-caretaker")

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

  defp parked!(ctx, budget_usd) do
    run = Run.start(uid("budget-run"), ctx.name, ctx.repo, :fixture, %{}, budget_usd)
    Run.budget_pause(run.run_id, "run budget rail hit: fixture", ["fixture"])
    parked = Run.get(run.run_id)
    assert parked.status == "budget_paused"
    assert is_binary(parked.budget_pause_id)
    parked
  end

  defp jobs(run_id) do
    Repo.aggregate(
      from(j in Oban.Job,
        where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run_id
      ),
      :count
    )
  end

  test "the direct handler requires verified human identity with no MCP caller fallback", ctx do
    run = parked!(ctx, 1.0)

    for actor <- [
          nil,
          %{},
          %{kind: :operator, id: ""},
          %{kind: :routine, id: ctx.caretaker},
          %{kind: :routine, id: ctx.worker},
          %{kind: :sub_agent, id: uid("helper")}
        ] do
      frame = %CallContext{assigns: %{custode_identity: actor}}

      assert {:reply, %Snodo.Result{kind: :error, value: message}, ^frame} =
               WorkflowBudgetTools.Resume.execute(
                 %{run_id: run.run_id, pause_id: run.budget_pause_id},
                 frame
               )

      assert message == "workflow budget resume refused: human_identity_required"
    end

    unchanged = Run.get(run.run_id)
    assert unchanged.status == "budget_paused"
    assert unchanged.budget_usd == 1.0
    assert unchanged.budget_pause_id == run.budget_pause_id
    assert ToolPolicy.fetch(@tool) == {:ok, :operator}

    for role <- [:caretaker, :backlog_worker] do
      refute @tool in Capabilities.exposed_tool_names(role)
    end
  end

  for protocol <- ["2025-11-25", "2026-07-28"] do
    @protocol protocol
    test "authenticated budget resume over HTTP #{@protocol}", ctx do
      assert Application.get_env(:custode, :oban_queues) == []
      human = Identity.mint(:operator, uid("budget-human"))
      initialize(human, @protocol)

      tool = Enum.find(discover(human, @protocol), &(&1["name"] == @tool))
      assert tool
      assert tool["inputSchema"] == WorkflowBudgetTools.Resume.input_schema()

      assert MapSet.new(tool["outputSchema"]["required"]) ==
               MapSet.new(WorkflowBudgetTools.Resume.output_schema()["required"])

      assert tool["outputSchema"]["properties"] ==
               WorkflowBudgetTools.Resume.output_schema()["properties"]

      run = parked!(ctx, 1.0)
      # Discover the resolving reference through the same HTTP surface an
      # independent client uses, rather than relying on internal run fields.
      attention = call(human, @protocol, "list_attention", %{"group" => "needs_you"})
      assert %{"result" => %{"content" => [%{"text" => attention_json}]}} = attention
      groups = Jason.decode!(attention_json)["groups"]

      action =
        groups
        |> Enum.flat_map(& &1["signals"])
        |> Enum.flat_map(& &1["resolving"])
        |> Enum.find(&(&1["op"] == "resume_run" and &1["args"]["run"] == run.run_id))

      assert action["args"]["pause"] == run.budget_pause_id
      args = %{"run_id" => action["args"]["run"], "pause_id" => action["args"]["pause"]}

      resumed = call(human, @protocol, @tool, args)
      assert %{"result" => %{"isError" => false, "structuredContent" => receipt}} = resumed

      assert receipt == %{
               "schema_version" => "custode.workflow_budget_resume.v1",
               "run_id" => run.run_id,
               "pause_id" => run.budget_pause_id,
               "decision" => "resumed",
               "previous_budget_usd" => 1.0,
               "budget_usd" => 2.0,
               "status" => "running"
             }

      assert Run.get(run.run_id).budget_usd == 2.0
      dispatched = jobs(run.run_id)

      # An exact retry returns the admission receipt and raises nothing again,
      # even once the run has parked on a new pause.
      assert %{"result" => %{"structuredContent" => ^receipt}} =
               call(human, @protocol, @tool, args)

      Run.budget_pause(run.run_id, "run budget rail hit: again", ["fixture"])
      repaused = Run.get(run.run_id)
      refute repaused.budget_pause_id == run.budget_pause_id

      assert %{"result" => %{"structuredContent" => ^receipt}} =
               call(human, @protocol, @tool, args)

      assert Run.get(run.run_id).status == "budget_paused"
      assert Run.get(run.run_id).budget_usd == 2.0
      assert jobs(run.run_id) == dispatched

      # A pause the run never took is stale; the current one is not substituted.
      assert_code(
        call(human, @protocol, @tool, %{"run_id" => run.run_id, "pause_id" => uid("pause")}),
        "stale_pause"
      )

      assert Run.get(run.run_id).budget_pause_id == repaused.budget_pause_id
      assert Run.get(run.run_id).budget_usd == 2.0

      assert_code(
        call(human, @protocol, @tool, %{"run_id" => uid("unknown"), "pause_id" => uid("pause")}),
        "no_such_run"
      )

      for arguments <- [
            %{"run_id" => run.run_id},
            %{"pause_id" => run.budget_pause_id},
            %{"run_id" => "", "pause_id" => run.budget_pause_id},
            %{"run_id" => run.run_id, "pause_id" => ""},
            %{"run_id" => String.duplicate("x", 1_025), "pause_id" => "p"},
            %{"run_id" => run.run_id, "pause_id" => String.duplicate("x", 161)},
            %{"run_id" => run.run_id, "pause_id" => 1},
            %{"run_id" => run.run_id, "pause_id" => "p", "budget_usd" => 99}
          ] do
        assert_invalid_arguments(human, @protocol, arguments)
      end

      assert_missing_arguments(human, @protocol)

      pending = parked!(ctx, 1.0)
      pending_args = %{"run_id" => pending.run_id, "pause_id" => pending.budget_pause_id}
      before = Repo.aggregate(Feed.Entry, :count)

      for id <- [ctx.worker, ctx.caretaker] do
        token = Identity.mint(:routine, id)
        initialize(token, @protocol)
        refute @tool in Enum.map(discover(token, @protocol), & &1["name"])
        assert_refused(call(token, @protocol, @tool, pending_args))
      end

      helper = Identity.mint(:sub_agent, uid("budget-helper"))

      for token <- [helper, nil] do
        response =
          post(token, @protocol, "tools/call", %{"name" => @tool, "arguments" => pending_args})

        assert response.status in [401, 403]
      end

      assert Repo.aggregate(Feed.Entry, :count) == before
      untouched = Run.get(pending.run_id)
      assert untouched.status == "budget_paused"
      assert untouched.budget_usd == 1.0
      assert untouched.budget_pause_id == pending.budget_pause_id
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

  # A missing required argument is a tool result, as in the decision tools.
  defp assert_missing_arguments(token, protocol) do
    response = post(token, protocol, "tools/call", %{"name" => @tool, "arguments" => %{}})
    assert response.status == 200

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} =
             response.body

    assert message =~ "Missing required arguments"
  end

  defp assert_invalid_arguments(token, protocol, args) do
    response = post(token, protocol, "tools/call", %{"name" => @tool, "arguments" => args})

    case response.body do
      %{"error" => %{"code" => -32_602}} ->
        expected_status = if protocol == "2026-07-28", do: 400, else: 200
        assert response.status == expected_status

      %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} ->
        assert response.status == 200
        assert message =~ "Missing required arguments"
    end
  end

  defp assert_code(response, code) do
    assert %{"result" => %{"isError" => true, "content" => [%{"text" => message}]}} = response
    assert message == "workflow budget resume refused: " <> code
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
