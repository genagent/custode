defmodule Custode.IntegrationCatalogAuditTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  alias Snodo.Client

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "tools/list" ->
            %{
              "tools" => [
                %{
                  "name" => "package_info",
                  "description" => "fixture package documentation",
                  "inputSchema" => %{"type" => "object"}
                }
              ]
            }

          "tools/call" ->
            %{"content" => [%{"type" => "text", "text" => "fixture package documentation"}]}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})
      )
    end
  end

  test "configured HTTP capability is invoked through separate real MCP clients" do
    server = start_supervised!({Bandit, plug: Endpoint, ip: {127, 0, 0, 1}, port: 0})
    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    url = "http://127.0.0.1:#{port}/mcp"

    put_env!(:external_mcp_servers, [
      %{name: "fixture-docs", url: url, allowed: ["mcp__fixture-docs__package_info"]}
    ])

    [integration] = Custode.MCP.external_servers()

    for _consumer <- [:first, :second] do
      {:ok, client} = Client.connect({:http, integration.url}, protocol: "2026-07-28")
      assert {:ok, [%{"name" => "package_info"}]} = Client.list_tools(client)

      assert {:ok, %{"content" => [%{"text" => "fixture package documentation"}]}} =
               Client.call_tool(client, "package_info", %{})

      assert :ok = Client.close(client)
    end
  end

  test "current helper configuration lacks the fleet external catalog" do
    put_env!(:external_mcp_servers, [%{name: "fixture-docs", url: "http://127.0.0.1:1/mcp"}])
    id = uid("catalog-helper")
    path = Custode.MCP.write_sub_agent_config!(id)
    on_exit(fn -> File.rm(path) end)
    config = path |> File.read!() |> Jason.decode!()
    assert Map.keys(config["mcpServers"]) == ["memory"]
    args = Custode.Routine.sub_agent_args(tmp_workspace!(), %{mcp_config_path: path})
    assert args["mcp_config"] == [path]
    refute Custode.MCP.external_config_path() in args["mcp_config"]
  end
end
