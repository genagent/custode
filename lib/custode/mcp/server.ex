defmodule Custode.MCP.Server do
  @moduledoc """
  The MCP server agents connect to (streamable HTTP on localhost, see
  `Custode.MCP`). Routines opt in per-entry with `mcp: true`, which adds the
  config-file reference and the `mcp__custode` tool allowlist to their claude
  args -- so which agents get fleet powers is a per-routine decision, gated by
  claude's own tool permissions.
  """

  use Anubis.Server,
    name: "custode",
    version: "0.1.0",
    capabilities: [:tools]

  component(Custode.MCP.Tools.ListRoutines, name: "list_routines")
  component(Custode.MCP.Tools.AgentStatus, name: "agent_status")
  component(Custode.MCP.Tools.StartAgent, name: "start_agent")
  component(Custode.MCP.Tools.PromptAgent, name: "prompt_agent")
  component(Custode.MCP.Tools.AwaitAgent, name: "await_agent")
  component(Custode.MCP.Tools.AgentHistory, name: "agent_history")
  component(Custode.MCP.Tools.ApproveAction, name: "approve_action")
  component(Custode.MCP.Tools.RejectAction, name: "reject_action")
  component(Custode.MCP.Tools.RunJob, name: "run_job")
end
