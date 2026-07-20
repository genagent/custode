defmodule Custode.MCP do
  @moduledoc """
  Shared plumbing for the MCP surface: the port, the `.mcp.json` config file
  claude subprocesses use to find the server, and the helpers the tools share.

  The server binds 127.0.0.1 only. Anything beyond localhost needs auth this
  demo deliberately does not have -- an unauthenticated "spawn agents that
  spend money" endpoint must not leave the machine.
  """

  def port, do: Application.get_env(:custode, :mcp_port, 6161)

  def url, do: "http://127.0.0.1:#{port()}/mcp"

  def config_path, do: Path.expand("tmp/custode_mcp.json")

  @doc "Write the `.mcp.json` file routines reference via their `mcp_config` arg."
  def write_config! do
    File.mkdir_p!(Path.dirname(config_path()))

    ClaudeWrapper.McpConfig.new()
    |> ClaudeWrapper.McpConfig.add_http("custode", url())
    |> ClaudeWrapper.McpConfig.write!(config_path())

    config_path()
  end

  @doc "The state atom out of a `ObanClaude.Agent.status/1` payload."
  def state_of({state, _payload}), do: state
  def state_of(state) when is_atom(state), do: state
end
