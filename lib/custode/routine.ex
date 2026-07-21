defmodule Custode.Routine do
  @moduledoc """
  Routine specs: config maps in, `ObanClaude.Agent.Tick` args out.

  A routine is one always-on agent: an id, a cron schedule, a workspace
  directory, and a beat prompt. `tick_args/1` turns it into a crontab entry
  that is the agent's WHOLE spec -- `if_offline: "start"` plus a JSON-clean
  `"start"` config -- so the schedule itself boots the agent cold, including
  after restarts. `session: "fresh"` every beat: the agent's memory is its
  workspace files, not the conversation.
  """

  alias Custode.Routine.Prompts

  @doc "All configured routines, with defaults applied."
  def all do
    for routine <- Application.fetch_env!(:custode, :routines), do: normalize(routine)
  end

  @doc "The routine with this id, or nil."
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The first configured routine (the default target for the console)."
  def default, do: hd(all())

  @doc "The crontab / Tick args for a routine: the complete agent spec."
  def tick_args(routine) do
    %{
      "agent_id" => routine.id,
      "prompt" => routine.prompt,
      "session" => "fresh",
      "if_busy" => "skip",
      "if_offline" => "start",
      "start" => %{
        "args" => claude_args(routine),
        # approvals may need more than reads (a gated delete runs rm; a repo
        # caretaker's approved edit runs in an isolated worktree)
        "approved_args" => routine.approved_args,
        "job_timeout" => 240_000
      }
    }
  end

  @doc """
  Claude args for a sub-agent started via the `start_agent` MCP tool: same
  shape as a routine agent, but no MCP tools (no recursive delegation) and a
  worker-bee default system prompt. `opts` are the tool's params.
  """
  def sub_agent_args(workspace, opts \\ %{}) do
    ObanClaude.Args.defaults(
      model: opts[:model] || Application.fetch_env!(:custode, :model),
      working_dir: Path.expand(workspace),
      permission_mode: :accept_edits,
      max_turns: 20,
      max_budget_usd: Application.fetch_env!(:custode, :max_budget_usd),
      timeout: 200_000,
      json_schema: directive_schema(),
      # the memory-only MCP server: persistence without delegation powers
      mcp_config: [Custode.MCP.memory_config_path()],
      allowed_tools: ["mcp__memory"],
      append_system_prompt: opts[:system_prompt] || sub_agent_prompt()
    )
  end

  defp claude_args(routine) do
    # No permission_mode: since bookkeeping goes through the notebook MCP
    # tools, a routine agent needs NO standing filesystem write permission --
    # claude's default mode denies writes non-interactively, and anything
    # write-shaped goes through the request_permission gate (whose approve
    # continuation carries :approved_args).
    base = [
      model: routine.model,
      working_dir: Path.expand(routine.working_dir),
      max_turns: 20,
      max_budget_usd: routine.max_budget_usd,
      timeout: 200_000,
      json_schema: directive_schema(),
      append_system_prompt: system_prompt(routine)
    ]

    mcp_tools = if routine.mcp, do: ["mcp__custode"], else: []
    allowed = mcp_tools ++ routine.extra_allowed_tools

    extra =
      if routine.mcp,
        do: [mcp_config: [Custode.MCP.config_path()]],
        else: []

    extra = if allowed == [], do: extra, else: Keyword.put(extra, :allowed_tools, allowed)

    ObanClaude.Args.defaults(base ++ extra)
  end

  defp system_prompt(%{mcp: true} = routine), do: routine.system_prompt <> delegation_prompt()
  defp system_prompt(routine), do: routine.system_prompt

  defp normalize(routine) do
    id = Map.fetch!(routine, :id)
    workspace = Map.fetch!(routine, :workspace)
    role = Map.get(routine, :role, :caretaker)

    %{
      id: id,
      cron: Map.fetch!(routine, :cron),
      # :workspace is the notebook home (inbox/, rendered journal.md/TODO.md);
      # :working_dir is where claude runs. They coincide for a plain
      # caretaker; a repo caretaker runs at the repo root while its notebook
      # lives in a subdirectory.
      workspace: workspace,
      working_dir: Map.get(routine, :working_dir, workspace),
      prompt: Map.fetch!(routine, :prompt),
      role: role,
      model: Map.get(routine, :model, Application.fetch_env!(:custode, :model)),
      max_budget_usd:
        Map.get(routine, :max_budget_usd, Application.fetch_env!(:custode, :max_budget_usd)),
      daily_budget_usd:
        Map.get(routine, :daily_budget_usd, Application.get_env(:custode, :daily_budget_usd)),
      system_prompt: Map.get(routine, :system_prompt, default_prompt(role, id)),
      # merged over the args on approve continuations only; a repo caretaker
      # adds "worktree" so approved edits land in an isolated branch
      approved_args:
        Map.get(routine, :approved_args, %{"permission_mode" => "bypass_permissions"}),
      # appended to the tool allowlist, e.g. read-only git Bash grants
      extra_allowed_tools: Map.get(routine, :extra_allowed_tools, []),
      mcp: Map.get(routine, :mcp, false)
    }
  end

  defp default_prompt(role, id), do: Prompts.for_role(role, id)

  defp directive_schema do
    Jason.encode!(%{
      type: "object",
      additionalProperties: false,
      required: ["directive", "summary"],
      properties: %{
        directive: %{type: "string", enum: ["none", "ask_user", "request_permission"]},
        summary: %{type: "string", description: "one-line sweep report"},
        question: %{type: "string", description: "set when directive=ask_user"},
        action: %{type: "string", description: "set when directive=request_permission"}
      }
    })
  end

  defp sub_agent_prompt, do: Prompts.sub_agent()

  defp delegation_prompt, do: Prompts.delegation()
end
