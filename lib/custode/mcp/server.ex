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

  # roster mutation (#75 / design 001 slice 3): preview is free, the write is
  # caller-guarded inside the tool
  component(Custode.MCP.RosterTools.PreviewRoutine, name: "preview_routine")
  component(Custode.MCP.RosterTools.AddRoutine, name: "add_routine")
  component(Custode.MCP.RosterTools.PreviewRoutineEdit, name: "preview_routine_edit")
  component(Custode.MCP.RosterTools.UpdateRoutine, name: "update_routine")
  component(Custode.MCP.RosterTools.RemoveRoutine, name: "remove_routine")
  component(Custode.MCP.ProfileTools.PreviewProfile, name: "preview_profile")
  component(Custode.MCP.ProfileTools.DefineProfile, name: "define_profile")
  component(Custode.MCP.ProfileTools.PreviewProfileEdit, name: "preview_profile_edit")
  component(Custode.MCP.ProfileTools.UpdateProfile, name: "update_profile")
  component(Custode.MCP.ProfileTools.RemoveProfile, name: "remove_profile")

  # graceful drain (#132): operator-only, async -- pause now, reply now,
  # stop when the executing turns finish
  component(Custode.MCP.Tools.Drain, name: "drain")

  # the repo verbs (issue #10): typed, policy-checked GitHub writes
  component(Custode.MCP.RepoTools.OpenPr, name: "repo_open_pr")
  component(Custode.MCP.RepoTools.OpenIssue, name: "repo_open_issue")
  component(Custode.MCP.RepoTools.Comment, name: "repo_comment")

  # the batch filing gate (#241): draft many, gate once, file what survives
  component(Custode.MCP.RepoTools.DraftIssues, name: "repo_draft_issues")
  component(Custode.MCP.RepoTools.FileDrafts, name: "repo_file_drafts")

  component(Custode.MCP.RepoTools.ReadyPr, name: "repo_ready_pr")
  component(Custode.MCP.RepoTools.MergePr, name: "repo_merge_pr")
  component(Custode.MCP.RepoTools.MarkIssueReady, name: "repo_mark_issue_ready")
  component(Custode.MCP.RepoTools.MarkIssueBlocked, name: "repo_mark_issue_blocked")
  component(Custode.MCP.RepoTools.ReviewPr, name: "repo_review_pr")

  # the repo READ verbs (issue #129): scoped GitHub reads, replacing the
  # unscoped gh Bash grants
  component(Custode.MCP.RepoTools.ListIssues, name: "repo_list_issues")
  component(Custode.MCP.RepoTools.ViewIssue, name: "repo_view_issue")
  component(Custode.MCP.RepoTools.ListPrs, name: "repo_list_prs")
  component(Custode.MCP.RepoTools.ViewPr, name: "repo_view_pr")
  component(Custode.MCP.RepoTools.PrChecks, name: "repo_pr_checks")
  component(Custode.MCP.RepoTools.PrDiff, name: "repo_pr_diff")

  # asking without blocking (#299): ask_operator is worker-tier, the two
  # reading/closing tools are the operator's
  component(Custode.MCP.AskTools.AskOperator, name: "ask_operator")
  component(Custode.MCP.AskTools.ListAsks, name: "list_asks")
  component(Custode.MCP.AskTools.AnswerAsk, name: "answer_ask")

  # the operator tier (issue #33): run the fleet, not just delegate into it
  component(Custode.MCP.OperatorTools.Beat, name: "beat")
  component(Custode.MCP.OperatorTools.DropNote, name: "drop_note")
  component(Custode.MCP.OperatorTools.ListGates, name: "list_gates")
  component(Custode.MCP.OperatorTools.FeedTail, name: "feed_tail")
  component(Custode.MCP.OperatorTools.PauseAgent, name: "pause_agent")
  component(Custode.MCP.OperatorTools.SetPresence, name: "set_presence")
  component(Custode.MCP.OperatorTools.ResumeAgent, name: "resume_agent")
  component(Custode.MCP.OperatorTools.SpendToday, name: "spend_today")

  component(Custode.MCP.NotebookTools.JournalAppend, name: "journal_append")
  component(Custode.MCP.NotebookTools.CompactJournal, name: "compact_journal")
  component(Custode.MCP.NotebookTools.SetPanel, name: "set_panel")
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
