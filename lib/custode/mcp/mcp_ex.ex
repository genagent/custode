defmodule Custode.MCP.MCPEx do
  @moduledoc false

  alias Custode.MCP.{MCPEx.Resources, MCPEx.Tools, MemoryServer, Server}
  alias MCP.{Router, Server.Runtime}
  alias MCP.Transport.Plug, as: MCPPlug

  @executor Custode.MCP.MCPEx.Executor
  @request_timeout :timer.minutes(16)
  @protocols [
    MCP.Protocol.V2026_07_28,
    MCP.Protocol.V2025_11_25,
    MCP.Protocol.V2025_06_18
  ]

  @spec executor() :: module()
  def executor, do: @executor

  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: Enum.map(@protocols, & &1.version())

  @spec executor_child_spec() :: {module(), keyword()}
  def executor_child_spec do
    {MCP.Server.Executor,
     name: @executor, max_concurrency: 16, max_queue: 64, default_timeout: @request_timeout}
  end

  @spec plug_options() :: %{{String.t(), atom()} => map()}
  def plug_options do
    full = tool_router(Server)
    memory = tool_router(MemoryServer)
    operator = Enum.reduce(Resources.modules(), full, &Router.register_resource(&2, &1))

    full_runtime = runtime(full, "custode", %{"tools" => %{}, "resources" => %{}})
    operator_runtime = runtime(operator, "custode", %{"tools" => %{}, "resources" => %{}})
    memory_runtime = runtime(memory, "memory", %{"tools" => %{}})

    for {path, kind, configured_runtime} <- [
          {"/mcp", :operator, operator_runtime},
          {"/mcp", :routine, full_runtime},
          {"/mcp", :sub_agent, full_runtime},
          {"/mcp/memory", :operator, memory_runtime},
          {"/mcp/memory", :routine, memory_runtime},
          {"/mcp/memory", :sub_agent, memory_runtime}
        ],
        into: %{} do
      {{path, kind},
       MCPPlug.init(
         runtime: configured_runtime,
         executor: @executor,
         path: path,
         request_timeout: @request_timeout
       )}
    end
  end

  defp tool_router(server) do
    Enum.reduce(server.__components__(:tool), Router.new(), fn component, router ->
      Router.register_tool(router, Tools.module(component.name))
    end)
  end

  defp runtime(router, name, capabilities) do
    Runtime.new(
      router: router,
      protocols: @protocols,
      capabilities: capabilities,
      server_info: %{"name" => name, "version" => "0.1.0"}
    )
  end
end
