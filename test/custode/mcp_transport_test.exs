defmodule Custode.MCPTransportTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]

  alias Custode.MCP.{Identity, MemoryServer, Server, WorkResources}
  alias Snodo.Client
  alias Snodo.Resource.Template

  @versions ["2025-06-18", "2025-11-25"]

  setup do
    routine_id = uid("mcp-routine")

    put_env!(:routines, [
      %{
        id: routine_id,
        role: :backlog_worker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "x"
      }
    ])

    %{routine_id: routine_id}
  end

  test "all advertised resource templates compile with Snodo" do
    failures =
      for %{name: name, uri: uri} <- WorkResources.template_definitions(),
          {:error, reason} <- [Template.compile(uri)] do
        {name, uri, reason}
      end

    assert failures == []
  end

  test "the current protocol serves authenticated tools and resources without initialize" do
    {:ok, token} = Identity.operator_token()

    assert {:ok, client} =
             Client.connect({:http, Custode.MCP.url()},
               protocol: "2026-07-28",
               headers: [{"authorization", "Bearer " <> token}]
             )

    assert {:ok, [_first | _rest]} = Client.list_tools(client)

    assert {:ok, %{"contents" => [%{"uri" => "custode://missions"}]}} =
             Client.read_resource(client, "custode://missions")

    assert :ok = Client.close(client)
  end

  test "initialize-era clients negotiate stateless HTTP without session ids" do
    {:ok, token} = Identity.operator_token()

    for version <- @versions do
      response = initialize("/mcp", token, version)
      assert response.body["result"]["protocolVersion"] == version
      assert Req.Response.get_header(response, "mcp-session-id") == []

      assert %Req.Response{status: 202} =
               notify("/mcp", token, version, "notifications/initialized")
    end
  end

  test "authorization filters operator, routine, and memory catalogs", ctx do
    {:ok, operator} = Identity.operator_token()
    routine = Identity.mint(:routine, ctx.routine_id)
    sub_agent = Identity.mint(:sub_agent, uid("mcp-sub"))
    version = "2025-06-18"

    initialize("/mcp", operator, version)
    operator_tools = discover("/mcp", operator, version, "tools/list", "tools")
    operator_resources = discover("/mcp", operator, version, "resources/list", "resources")

    operator_templates =
      discover("/mcp", operator, version, "resources/templates/list", "resourceTemplates")

    assert Enum.sort(Enum.map(operator_tools, & &1["name"])) ==
             Server.tools() |> Enum.map(& &1.name()) |> Enum.sort()

    assert Enum.sort(Enum.map(operator_resources, & &1["name"])) ==
             WorkResources.resource_definitions() |> Enum.map(& &1.name) |> Enum.sort()

    assert Enum.sort(Enum.map(operator_templates, & &1["name"])) ==
             WorkResources.template_definitions() |> Enum.map(& &1.name) |> Enum.sort()

    assert %{"contents" => [%{"uri" => "custode://missions"}]} =
             result(
               rpc("/mcp", operator, version, 5, "resources/read", %{
                 "uri" => "custode://missions"
               })
             )

    initialize("/mcp", routine, version)
    assert result(rpc("/mcp", routine, version, 6, "resources/list"))["resources"] == []

    assert result(rpc("/mcp", routine, version, 7, "resources/templates/list"))[
             "resourceTemplates"
           ] == []

    initialize("/mcp/memory", sub_agent, version)
    memory_tools = result(rpc("/mcp/memory", sub_agent, version, 8, "tools/list"))["tools"]

    assert Enum.sort(Enum.map(memory_tools, & &1["name"])) ==
             MemoryServer.tools() |> Enum.map(& &1.name()) |> Enum.sort()
  end

  test "memory endpoint performs a controlled self-scoped write through the legacy callbacks" do
    agent_id = uid("mcp-write")
    token = Identity.mint(:sub_agent, agent_id)
    key = uid("transport-key")
    value = "Research stays on the Ligurian coast in November."
    version = "2025-11-25"

    initialize("/mcp/memory", token, version)

    assert %{"isError" => false} =
             result(
               rpc("/mcp/memory", token, version, 2, "tools/call", %{
                 "name" => "remember",
                 "arguments" => %{"key" => key, "value" => value}
               })
             )

    assert {:ok, ^value} = Custode.Memory.recall(agent_id, key)

    assert %{"isError" => false, "content" => [%{"text" => encoded} | _rest]} =
             result(
               rpc("/mcp/memory", token, version, 3, "tools/call", %{
                 "name" => "recall",
                 "arguments" => %{"key" => key}
               })
             )

    assert Jason.decode!(encoded)["value"] == value
  end

  test "missing schema-required arguments are correctable tool errors" do
    {:ok, token} = Identity.operator_token()

    for version <- @versions do
      initialize("/mcp", token, version)

      assert %{"isError" => true, "content" => [%{"text" => message} | _rest]} =
               result(
                 rpc("/mcp", token, version, 4, "tools/call", %{
                   "name" => "agent_status",
                   "arguments" => %{}
                 })
               )

      assert message == "Missing required arguments: agent_id"
    end
  end

  test "a stale approval is an HTTP 200 tool error and recovers its durable gate", ctx do
    {:ok, operator} = Identity.operator_token()
    version = "2025-11-25"

    gate =
      Custode.Repo.insert!(%Custode.Gates.Gate{
        agent_id: ctx.routine_id,
        kind: "approval",
        action_id: uid("act-stale"),
        detail: "action from a departed provider process"
      })

    initialize("/mcp", operator, version)

    response =
      rpc("/mcp", operator, version, 9, "tools/call", %{
        "name" => "approve_action",
        "arguments" => %{"agent_id" => ctx.routine_id, "action_id" => gate.action_id}
      })

    assert %{"isError" => true, "content" => [%{"text" => message} | _rest]} = result(response)
    assert message =~ "rehydration_required"
    assert Custode.Repo.get!(Custode.Gates.Gate, gate.id).status == "requeued"
  end

  defp initialize(path, token, version) do
    response =
      post(path, token, nil, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{
          "protocolVersion" => version,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "custode-acceptance", "version" => "1"}
        }
      })

    assert response.status == 200, inspect(response.body)
    response
  end

  defp notify(path, token, version, method) do
    post(path, token, version, %{"jsonrpc" => "2.0", "method" => method})
  end

  defp discover(path, token, version, method, kind, params \\ %{}, seen \\ MapSet.new()) do
    page = result(rpc(path, token, version, System.unique_integer([:positive]), method, params))

    case page["nextCursor"] do
      nil ->
        page[kind]

      cursor ->
        refute MapSet.member?(seen, cursor)

        page[kind] ++
          discover(
            path,
            token,
            version,
            method,
            kind,
            %{"cursor" => cursor},
            MapSet.put(seen, cursor)
          )
    end
  end

  defp rpc(path, token, version, id, method, params \\ %{}) do
    response =
      post(path, token, version, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "method" => method,
        "params" => params
      })

    assert response.status == 200, inspect(response.body)
    response.body
  end

  defp result(%{"result" => result}), do: result

  defp post(path, token, version, body) do
    headers = [
      {"accept", "application/json, text/event-stream"},
      {"authorization", "Bearer " <> token}
    ]

    headers = if version, do: [{"mcp-protocol-version", version} | headers], else: headers

    url = if path == "/mcp/memory", do: Custode.MCP.memory_url(), else: Custode.MCP.url()

    Req.post!(url,
      json: body,
      headers: headers,
      retry: false,
      connect_options: [timeout: 1_000],
      receive_timeout: 5_000
    )
  end
end
