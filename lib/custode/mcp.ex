defmodule Custode.MCP do
  @moduledoc """
  Shared plumbing for the MCP surface: the port, the `.mcp.json` config file
  claude subprocesses use to find the server, and the helpers the tools share.

  The server binds 127.0.0.1 only. Anything beyond localhost needs auth this
  demo deliberately does not have -- an unauthenticated "spawn agents that
  spend money" endpoint must not leave the machine.
  """

  alias Custode.MCP.Identity

  def port, do: Application.get_env(:custode, :mcp_port, 6161)

  def url, do: "http://127.0.0.1:#{port()}/mcp"

  def memory_url, do: url() <> "/memory"

  # Configurable so the TEST env writes (and deletes) its own copies: the
  # suite runs from the same directory as a live server, and a shared path
  # cost three separate command_failed incidents before the failure detail
  # finally named it (a test on_exit was deleting the live external file).
  def config_path, do: Path.expand(Path.join(config_dir(), "custode_mcp.json"))

  @doc "Per-routine full-tier config (carries the routine's bearer token, #2)."
  def config_path(routine_id),
    do: Path.expand(Path.join(config_dir(), "agent_#{routine_id}.json"))

  @doc "Per-sub-agent memory-tier config, written at spawn."
  def sub_agent_config_path(agent_id),
    do: Path.expand(Path.join(config_dir(), "sub_#{agent_id}.json"))

  def memory_config_path, do: Path.expand(Path.join(config_dir(), "custode_mcp_memory.json"))

  def external_config_path, do: Path.expand(Path.join(config_dir(), "custode_mcp_external.json"))

  defp config_dir, do: Application.get_env(:custode, :mcp_config_dir, "tmp")

  @doc """
  Fleet-wide external MCP servers (issue #46): configured once, written into
  one shared config file every `mcp: true` routine references, with their
  tool grants appended to every allowlist. Explicit and declared -- the
  opposite of the user-scope leak that surfaced during #4.
  """
  def external_servers do
    for server <- Application.get_env(:custode, :external_mcp_servers, []) do
      %{
        name: Map.fetch!(server, :name),
        type: Map.get(server, :type, :http),
        url: Map.get(server, :url),
        command: Map.get(server, :command),
        args: Map.get(server, :args, []),
        allowed: Map.get(server, :allowed, ["mcp__" <> Map.fetch!(server, :name)])
      }
    end
  end

  @doc "The allowlist grants every external server contributes."
  def external_allowed, do: Enum.flat_map(external_servers(), & &1.allowed)

  @doc "The mcp_config file list a routine's claude args should carry."
  def config_paths(routine_id) do
    case external_servers() do
      [] -> [config_path(routine_id)]
      _some -> [config_path(routine_id), external_config_path()]
    end
  end

  @doc """
  Write the `.mcp.json` files agents reference via their `mcp_config` arg:
  one PER ROUTINE carrying that routine's bearer token (#2 -- the token IS
  the caller identity the router verifies), plus the shared external
  servers file. Requires `Custode.MCP.Identity` to be running; invoked
  from a boot task after it, and before the ticks queue opens.
  """
  def write_config! do
    File.mkdir_p!(Path.dirname(config_path()))

    for routine <- Custode.Routine.all() do
      write_routine_config!(routine.id)
    end

    case external_servers() do
      [] ->
        :ok

      servers ->
        servers
        |> Enum.reduce(ClaudeWrapper.McpConfig.new(), &add_external/2)
        |> ClaudeWrapper.McpConfig.write!(external_config_path())
    end

    :ok
  end

  @doc """
  Mint (or re-mint) a routine's identity and write its per-routine MCP config
  file. Boot calls this for every roster entry; runtime adds (#75's
  write-back) call it for the newcomer so "beatable immediately" holds for
  mcp: true routines too -- a routine without this file fails every turn
  with command_failed until someone writes it.
  """
  def write_routine_config!(routine_id) do
    token = Identity.mint(:routine, routine_id)

    ClaudeWrapper.McpConfig.new()
    |> ClaudeWrapper.McpConfig.add_http("custode", url(),
      headers: %{"Authorization" => "Bearer " <> token}
    )
    |> ClaudeWrapper.McpConfig.write!(config_path(routine_id))
  end

  @doc "Mint an identity and write the memory-tier config for one sub-agent."
  def write_sub_agent_config!(agent_id) do
    token = Identity.mint(:sub_agent, agent_id)

    ClaudeWrapper.McpConfig.new()
    |> ClaudeWrapper.McpConfig.add_http("memory", memory_url(),
      headers: %{"Authorization" => "Bearer " <> token}
    )
    |> ClaudeWrapper.McpConfig.write!(sub_agent_config_path(agent_id))

    sub_agent_config_path(agent_id)
  end

  @doc "The caller identity a tool sees: `%{kind:, id:}` or :operator context."
  def caller(%{assigns: %{custode_identity: identity}}), do: identity
  def caller(_frame), do: %{kind: :operator, id: "operator"}

  @doc "The authenticated request's originating transport; direct tool calls are MCP."
  def origin_transport(%{assigns: %{custode_transport: transport}})
      when transport in [:cli, :mcp],
      do: transport

  def origin_transport(_frame), do: :mcp

  defp add_external(%{type: :http, name: name, url: url}, config) when is_binary(url),
    do: ClaudeWrapper.McpConfig.add_http(config, name, url)

  defp add_external(%{type: :sse, name: name, url: url}, config) when is_binary(url),
    do: ClaudeWrapper.McpConfig.add_sse(config, name, url)

  defp add_external(%{type: :stdio, name: name, command: command, args: args}, config)
       when is_binary(command),
       do: ClaudeWrapper.McpConfig.add_stdio(config, name, command, args)

  @doc "The state atom out of a `ObanClaude.Agent.status/1` payload."
  defdelegate state_of(status), to: Custode
end
