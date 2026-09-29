defmodule Custode.MCPPermissionDecideTransportTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Feed
  alias Custode.MCP.Identity

  setup do
    workspace = tmp_workspace!()

    routine =
      routine_fixture!(workspace, %{
        role: :backlog_worker,
        cron: :manual,
        mcp: true,
        repo: "acme/" <> uid("permission-repo")
      })

    %{routine: routine, client: session(Identity.mint(:routine, routine.id))}
  end

  test "a routine discovers and calls the broker without adding it to its work allowlist", ctx do
    assert "permission_decide" in tool_names(ctx.client)

    refute "mcp__custode__permission_decide" in Custode.Routine.mcp_tools(ctx.routine.role)

    input = %{"repo" => ctx.routine.repo, "state" => "open"}

    assert %{"behavior" => "allow", "updatedInput" => ^input} =
             call(ctx.client, "permission_decide", %{
               tool_name: "mcp__custode__repo_list_issues",
               input: input,
               tool_use_id: "toolu_transport_test"
             })
  end

  test "an out-of-role read returns a deny decision through the normal tool envelope", ctx do
    assert %{"behavior" => "deny", "message" => message} =
             call(ctx.client, "permission_decide", %{
               tool_name: "mcp__custode__list_attention",
               input: %{}
             })

    assert is_binary(message)
    assert message != ""
  end

  test "schema-invalid requests fail before the broker and create no audit", ctx do
    assert Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 10) == []

    assert %{
             "result" => %{
               "isError" => true,
               "content" => [%{"text" => missing_input} | _rest]
             }
           } =
             rpc(ctx.client, "tools/call", %{
               name: "permission_decide",
               arguments: %{tool_name: "mcp__custode__repo_list_issues"}
             })

    assert missing_input =~ "Missing required arguments"

    assert %{"error" => %{"code" => -32_602}} =
             rpc(ctx.client, "tools/call", %{
               name: "permission_decide",
               arguments: %{
                 tool_name: "mcp__custode__repo_list_issues",
                 input: "not an object"
               }
             })

    assert Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 10) == []
  end

  defp tool_names(client) do
    %{"result" => %{"tools" => tools}} = rpc(client, "tools/list", %{})
    Enum.map(tools, & &1["name"])
  end

  defp call(client, tool, arguments) do
    %{"result" => %{"isError" => false, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    Jason.decode!(text)
  end

  defp session(token) do
    version = "2025-06-18"
    client = %{url: url(), headers: headers(token)}

    assert post(client, %{
             jsonrpc: "2.0",
             id: 1,
             method: "initialize",
             params: %{
               protocolVersion: version,
               capabilities: %{},
               clientInfo: %{name: "permission-decide-test", version: "0"}
             }
           }).status == 200

    client = %{client | headers: [{"mcp-protocol-version", version} | client.headers]}
    assert post(client, %{jsonrpc: "2.0", method: "notifications/initialized"}).status == 202
    client
  end

  defp rpc(client, method, params) do
    response =
      post(client, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      })

    assert response.status == 200
    decode(response.body)
  end

  defp post(client, body) do
    Req.post!(client.url, json: body, headers: client.headers, retry: false)
  end

  defp url, do: "http://127.0.0.1:#{Custode.MCP.port()}/mcp"

  defp headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/json, text/event-stream"}
    ]
  end

  defp decode(body) when is_map(body), do: body

  defp decode(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> data -> Jason.decode!(data)
      _line -> nil
    end)
    |> Kernel.||(Jason.decode!(body))
  end
end
