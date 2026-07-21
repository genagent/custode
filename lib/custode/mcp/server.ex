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

  # the repo verbs (issue #10): typed, policy-checked GitHub writes
  component(Custode.MCP.RepoTools.OpenPr, name: "repo_open_pr")
  component(Custode.MCP.RepoTools.Comment, name: "repo_comment")
  component(Custode.MCP.RepoTools.ReadyPr, name: "repo_ready_pr")
  component(Custode.MCP.RepoTools.MergePr, name: "repo_merge_pr")

  # the operator tier (issue #33): run the fleet, not just delegate into it
  component(Custode.MCP.OperatorTools.Beat, name: "beat")
  component(Custode.MCP.OperatorTools.DropNote, name: "drop_note")
  component(Custode.MCP.OperatorTools.ListGates, name: "list_gates")
  component(Custode.MCP.OperatorTools.FeedTail, name: "feed_tail")
  component(Custode.MCP.OperatorTools.PauseAgent, name: "pause_agent")
  component(Custode.MCP.OperatorTools.ResumeAgent, name: "resume_agent")
  component(Custode.MCP.OperatorTools.SpendToday, name: "spend_today")

  component(Custode.MCP.NotebookTools.JournalAppend, name: "journal_append")
  component(Custode.MCP.NotebookTools.TodoAdd, name: "todo_add")
  component(Custode.MCP.NotebookTools.TodoList, name: "todo_list")
  component(Custode.MCP.NotebookTools.TodoComplete, name: "todo_complete")
  component(Custode.MCP.NotebookTools.InboxList, name: "inbox_list")
  component(Custode.MCP.NotebookTools.InboxMarkFiled, name: "inbox_mark_filed")

  component(Custode.MCP.MemoryTools.Remember, name: "remember")
  component(Custode.MCP.MemoryTools.Recall, name: "recall")
  component(Custode.MCP.MemoryTools.Forget, name: "forget")
end

defmodule Custode.MCP.MemoryServer do
  @moduledoc """
  The capability-scoped MCP server for sub-agents: ONLY the persistent memory
  tools. Sub-agents get this endpoint (never the full one), so they can carry
  facts across their own sessions without gaining delegation, notebook, or
  lifecycle powers.
  """

  use Anubis.Server,
    name: "memory",
    version: "0.1.0",
    capabilities: [:tools]

  component(Custode.MCP.MemoryTools.Remember, name: "remember")
  component(Custode.MCP.MemoryTools.Recall, name: "recall")
  component(Custode.MCP.MemoryTools.Forget, name: "forget")
end
