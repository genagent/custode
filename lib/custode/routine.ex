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

  @doc """
  The full Cron crontab: one Tick entry per scheduled routine (`cron:
  :manual` routines are skipped -- identity, tile, and budgets without a
  schedule) plus one entry per configured sensor (plain workers on the
  `:sensors` queue; see `Custode.Sensors.ContributorSearch`).
  """
  def crontab do
    routine_entries =
      for routine <- all(), routine.cron != :manual do
        {routine.cron, ObanClaude.Agent.Tick, args: tick_args(routine), queue: :ticks}
      end

    sensor_entries =
      for sensor <- sensors() do
        args = Map.merge(%{"sensor_id" => sensor.id, "notify" => sensor.notify}, sensor.args)
        {sensor.cron, sensor.module, args: args, queue: :sensors}
      end

    janitor_entries = [{"@daily", Custode.Janitor, args: %{}, queue: :sensors}]

    routine_entries ++ sensor_entries ++ janitor_entries
  end

  @doc "Configured sensors, normalized."
  def sensors do
    for sensor <- Application.get_env(:custode, :sensors, []) do
      %{
        id: Map.fetch!(sensor, :id),
        cron: Map.fetch!(sensor, :cron),
        module: Map.fetch!(sensor, :module),
        notify: Map.fetch!(sensor, :notify),
        args: Map.get(sensor, :args, %{})
      }
    end
  end

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
        # the machine watchdog must outlast the subprocess cap
        "job_timeout" => routine.timeout_ms + 60_000
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
      max_turns: routine.max_turns,
      max_budget_usd: routine.max_budget_usd,
      timeout: routine.timeout_ms,
      json_schema: directive_schema(),
      append_system_prompt: system_prompt(routine)
    ]

    mcp_tools =
      if routine.mcp,
        do: mcp_allowlist(routine.role) ++ Custode.MCP.external_allowed(),
        else: []

    allowed = mcp_tools ++ routine.extra_allowed_tools

    extra =
      if routine.mcp,
        do: [mcp_config: Custode.MCP.config_paths()],
        else: []

    extra = if allowed == [], do: extra, else: Keyword.put(extra, :allowed_tools, allowed)

    ObanClaude.Args.defaults(base ++ extra)
  end

  # Policies (#50) append to EVERY prompt, including operator-supplied
  # system_prompt: overrides -- fleet law rides along regardless of role.
  defp system_prompt(%{mcp: true} = routine),
    do: routine.system_prompt <> delegation_prompt() <> Custode.Policy.render(routine)

  defp system_prompt(routine), do: routine.system_prompt <> Custode.Policy.render(routine)

  # Tool tiers (issue #40): the operator verbs (pause a sibling, beat a
  # routine, read the fleet) belong to the meta-agent only. Every other
  # mcp: true routine gets delegation over its OWN sub-agents plus its
  # notebook and memory. Allowlist-deep, not identity-deep (that is #2) --
  # but it removes the casual path to a backlog worker pausing the fleet.
  @worker_mcp_tools ~w(
    list_routines agent_status start_agent prompt_agent await_agent
    agent_history approve_action reject_action run_job
    journal_append todo_add todo_list todo_complete inbox_list inbox_mark_filed
    remember recall forget
  )

  @operator_mcp_tools ~w(
    beat drop_note list_gates feed_tail pause_agent resume_agent spend_today
  )

  defp mcp_allowlist(:caretaker),
    do: Enum.map(@worker_mcp_tools ++ @operator_mcp_tools, &("mcp__custode__" <> &1))

  defp mcp_allowlist(_role), do: Enum.map(@worker_mcp_tools, &("mcp__custode__" <> &1))

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
      # the token rail (#30): same auto-pause as the dollar rail, denominated
      # in throughput tokens; nil (the default) disables
      daily_budget_tokens:
        Map.get(
          routine,
          :daily_budget_tokens,
          Application.get_env(:custode, :daily_budget_tokens)
        ),
      # the claude subprocess cap per turn; long implementation turns (opus +
      # a test suite) need more than the chatty default
      timeout_ms: Map.get(routine, :timeout_ms, 200_000),
      # agentic turns inside one claude run; an approved implementation
      # (edit + build + test loops) needs far more than a sweep
      max_turns: Map.get(routine, :max_turns, 20),
      system_prompt: Map.get(routine, :system_prompt, default_prompt(role, id)),
      # merged over the args on approve continuations only; a repo caretaker
      # adds "worktree" so approved edits land in an isolated branch
      approved_args:
        Map.get(routine, :approved_args, %{"permission_mode" => "bypass_permissions"}),
      # appended to the tool allowlist, e.g. read-only git Bash grants
      extra_allowed_tools: Map.get(routine, :extra_allowed_tools, []),
      # the event kickoff: a dropped inbox note schedules a debounced beat
      # (:beat, default) or does nothing (:ignore)
      on_note: Map.get(routine, :on_note, :beat),
      # "owner/name" ties the routine to one GitHub repo: its agent page
      # grows issue/PR panels (Custode.GitHub). nil for multi-repo routines.
      repo: Map.get(routine, :repo),
      # classification (#51): fleet-page filtering now, policy scoping (#50)
      # next. Atoms in config; strings would survive a JSON trip identically.
      tags: Map.get(routine, :tags, []),
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
