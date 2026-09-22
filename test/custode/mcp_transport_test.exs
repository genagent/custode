defmodule Custode.MCPTransportTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1]

  alias Custode.MCP.{Identity, MemoryServer, Server, WorkResources}

  @versions ["2025-06-18", "2025-11-25"]

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

  test "identity catalogs preserve full, operator-resource, and memory endpoint isolation" do
    {:ok, operator} = Identity.operator_token()
    routine = Identity.mint(:routine, uid("mcp-routine"))
    sub_agent = Identity.mint(:sub_agent, uid("mcp-sub"))
    version = "2025-06-18"

    initialize("/mcp", operator, version)
    operator_tools = result(rpc("/mcp", operator, version, 2, "tools/list"))["tools"]
    operator_resources = result(rpc("/mcp", operator, version, 3, "resources/list"))["resources"]

    operator_templates =
      result(rpc("/mcp", operator, version, 4, "resources/templates/list"))[
        "resourceTemplates"
      ]

    assert Enum.sort(Enum.map(operator_tools, & &1["name"])) ==
             Server.__components__(:tool) |> Enum.map(& &1.name) |> Enum.sort()

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
             MemoryServer.__components__(:tool) |> Enum.map(& &1.name) |> Enum.sort()
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
