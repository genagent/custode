defmodule Custode.MCP.Snodo do
  @moduledoc false

  alias Custode.MCP.{Capabilities, MemoryServer, Server, Snodo.Resources, Snodo.Tools}
  alias Snodo.{Router, Server.Runtime}
  alias Snodo.Transport.Plug, as: SnodoPlug

  @executor Custode.MCP.Snodo.Executor
  @request_timeout :timer.minutes(16)
  @protocols [
    Snodo.Protocol.V2026_07_28,
    Snodo.Protocol.V2025_11_25,
    Snodo.Protocol.V2025_06_18
  ]

  @spec executor() :: module()
  def executor, do: @executor

  @spec protocol_versions() :: [String.t()]
  def protocol_versions, do: Enum.map(@protocols, & &1.version())

  @spec executor_child_spec() :: {module(), keyword()}
  def executor_child_spec do
    {Snodo.Server.Executor,
     name: @executor, max_concurrency: 16, max_queue: 64, default_timeout: @request_timeout}
  end

  @spec plug_options() :: %{String.t() => map()}
  def plug_options do
    full = tool_router(Server)
    memory = tool_router(MemoryServer)
    operator = Enum.reduce(Resources.modules(), full, &Router.register_resource(&2, &1))

    for {path, configured_runtime} <- [
          {"/mcp", runtime(operator, "custode", :main, %{"tools" => %{}, "resources" => %{}})},
          {"/mcp/memory", runtime(memory, "memory", :memory, %{"tools" => %{}})}
        ],
        into: %{} do
      {path,
       SnodoPlug.init(
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

  defp runtime(router, name, endpoint, capabilities) do
    Runtime.new(
      router: router,
      protocols: @protocols,
      capabilities: capabilities,
      authorization: {Capabilities, endpoint},
      server_info: %{"name" => name, "version" => "0.2.0"}
    )
  end
end
