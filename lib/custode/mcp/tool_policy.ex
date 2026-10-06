defmodule Custode.MCP.ToolPolicy do
  @moduledoc """
  What kind of thing every registered MCP tool does (#528).

  The write verbs are checked against the approved gate's class
  (`Custode.Gates.Grant`, #451), but which tools ARE write verbs was only
  knowable by reading each tool's `execute/2`. This is that knowledge as one
  table, and `test/custode/mcp/tool_policy_test.exs` walks every server's
  registered components and fails, naming the tool, when one has no entry. A
  new tool cannot ship unclassified.

  It records; nothing at runtime reads it. The guard each category names is
  still the call inside the tool.

  ## Categories

    * `:read` -- changes nothing.
    * `:self_write` -- writes only the caller's own records (notebook, memory,
      asks, drafts, disowned PRs). The guard is `check_self/2`, or the row is
      keyed by the caller's id.
    * `{:repo_write, verb}` -- a GitHub write. It must pass `verb` to
      `granted/3` or `check_grant/2` (`Custode.MCP.Tools`).
    * `:delegate` -- drives another agent: start, prompt, decide its gate.
      Worker-tier, over the caller's own sub-agents (`check_gate_target/2`).
    * `:peer_message` -- sends or acknowledges routine-to-routine messages.
      The shared peer service checks authenticated participants. Messages are
      requests or evidence and confer no authority over the recipient.
    * `:roster_write` -- mutates the roster or a profile. Caretaker-only
      (`RosterTools.check_roster_writer/1`).
    * `:operator` -- runs the fleet. Endpoint and role admission is enforced by
      `Custode.MCP.Capabilities`; individual operations can be narrower.
  """

  @type category ::
          :read
          | :self_write
          | {:repo_write, atom()}
          | :delegate
          | :peer_message
          | :roster_write
          | :operator

  @policy %{
    # delegation
    "list_routines" => :read,
    "agent_status" => :read,
    "await_agent" => :read,
    "agent_history" => :read,
    "start_agent" => :delegate,
    "prompt_agent" => :delegate,
    "approve_action" => :delegate,
    "reject_action" => :delegate,
    "run_job" => :delegate,
    "owner_review" => :delegate,
    "read_composition" => :self_write,
    "read_composition_configure" => :operator,
    "assurance_read" => :read,
    # Read actions retain root/context records; exact grants also guard Git reads.
    "subject_context" => :self_write,
    "subject_assignment" => :operator,
    # Scoped diff is read-only; typed feedback retains comment rows, never applies source.
    "return_context" => :self_write,
    # roster and profiles: a preview writes nothing
    "preview_routine" => :read,
    "preview_routine_edit" => :read,
    "preview_profile" => :read,
    "preview_profile_edit" => :read,
    "add_routine" => :roster_write,
    "update_routine" => :roster_write,
    "remove_routine" => :roster_write,
    "define_profile" => :roster_write,
    "update_profile" => :roster_write,
    "remove_profile" => :roster_write,
    # the repo verbs
    "repo_open_pr" => {:repo_write, :open_pr},
    "repo_open_issue" => {:repo_write, :open_issue},
    "repo_comment" => {:repo_write, :comment},
    "repo_file_drafts" => {:repo_write, :file_drafts},
    "repo_ready_pr" => {:repo_write, :ready_pr},
    "repo_merge_pr" => {:repo_write, :merge_pr},
    "repo_mark_issue_ready" => {:repo_write, :mark_issue},
    "repo_mark_issue_blocked" => {:repo_write, :mark_issue},
    "repo_review_pr" => {:repo_write, :review_pr},
    # a draft batch is rows in custode's own db until repo_file_drafts (#241)
    "repo_draft_issues" => :self_write,
    "repo_list_issues" => :read,
    "repo_view_issue" => :read,
    "repo_list_prs" => :read,
    "repo_view_pr" => :read,
    "repo_pr_checks" => :read,
    "repo_pr_diff" => :read,
    # disowning is a row keyed by the caller, not a GitHub write (#313)
    "repo_disown_pr" => :self_write,
    "repo_reclaim_pr" => :self_write,
    "list_disowned" => :read,
    # asks
    "ask_operator" => :self_write,
    "list_asks" => :read,
    "answer_ask" => :operator,
    "dismiss_ask" => :operator,
    # peer correspondence never delegates approval or lifecycle authority
    "peer_send" => :peer_message,
    "peer_reply" => :peer_message,
    "peer_ack" => :peer_message,
    "peer_list" => :read,
    "peer_read" => :read,
    # the fleet-wide reads (#346)
    "list_attention" => :read,
    "list_inbox" => :read,
    "list_suggestions" => :read,
    "list_suggestion_outcomes" => :read,
    "list_advisors" => :read,
    "metrics" => :read,
    "digest" => :read,
    "list_roles" => :read,
    "list_policies" => :read,
    "list_workflows" => :read,
    "workflow_retry_status" => :read,
    "executing_turns" => :read,
    "operator_bootstrap" => :read,
    "project_progress" => :read,
    # Agreement records do not dispatch work or grant execution authority.
    "work_agreement_read" => :read,
    "work_agreement_create" => :operator,
    "work_agreement_revise" => :operator,
    "work_agreement_checkpoint" => :self_write,
    "work_agreement_submit" => :self_write,
    "work_agreement_resolve" => :operator,
    "project_report_digest" => :read,
    "current_run" => :read,
    "integration_list" => :read,
    "integration_access_update" => :operator,
    "route_preview" => :read,
    # the operator tier
    "beat" => :operator,
    "drop_note" => :operator,
    "pause_agent" => :operator,
    "resume_agent" => :operator,
    "set_presence" => :operator,
    "drain" => :operator,
    "list_gates" => :read,
    "feed_tail" => :read,
    "list_operator_messages" => :read,
    "spend_today" => :read,
    "provision_owned_checkout" => :operator,
    "refresh_owned_checkout" => :operator,
    # notebook
    "journal_append" => :self_write,
    "journal_read" => :read,
    "compact_journal" => :self_write,
    "set_panel" => :self_write,
    "set_next_beat" => :self_write,
    "todo_add" => :self_write,
    "todo_complete" => :self_write,
    "inbox_mark_filed" => :self_write,
    "todo_list" => :read,
    "inbox_list" => :read,
    # memory
    "remember" => :self_write,
    "forget" => :self_write,
    "recall" => :read
  }

  # Write verbs no gate class covers (#451's table). A grant of any bounded
  # class judges these `:outside_class`, so under `:enforce` only an `other`
  # or undeclared gate lets them through. Listed so that stays a visible
  # decision: adding a verb to a class is a change to `Custode.Gates.Class`,
  # never a side effect of registering a tool.
  @in_no_class [:mark_issue]

  @doc "Every MCP server whose components the table must cover."
  @spec servers() :: [module()]
  def servers, do: [Custode.MCP.Server, Custode.MCP.MemoryServer]

  @doc "The whole table, tool name to category."
  @spec all() :: %{String.t() => category()}
  def all, do: @policy

  @doc """
  The category of one tool, or `:error` for a name with no entry.

      iex> Custode.MCP.ToolPolicy.fetch("repo_merge_pr")
      {:ok, {:repo_write, :merge_pr}}
      iex> Custode.MCP.ToolPolicy.fetch("nope")
      :error
  """
  @spec fetch(String.t()) :: {:ok, category()} | :error
  def fetch(tool), do: Map.fetch(@policy, tool)

  @doc "Each repo write tool with the verb it must pass to the grant check."
  @spec repo_writes() :: %{String.t() => atom()}
  def repo_writes do
    for {tool, {:repo_write, verb}} <- @policy, into: %{}, do: {tool, verb}
  end

  @doc "The write verbs that are in no gate class."
  @spec in_no_class() :: [atom()]
  def in_no_class, do: @in_no_class
end
