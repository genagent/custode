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

  @doc "All configured routines, with profile and defaults applied."
  def all do
    for routine <- Application.fetch_env!(:custode, :routines), do: normalize(routine)
  end

  @doc """
  Named profiles (the operational envelope layer of the #38 vocabulary):
  a routine says `profile: :backlog_worker` and inherits the whole envelope
  -- cadence, model, budgets, grants, approved_args, tags, implied sensors
  -- then overrides whatever it likes (the routine entry always wins; tags
  union). "Set up an agent to watch repo X as a backlog worker" is exactly
  a profile name plus an assignment (#75).
  """
  def profiles, do: Application.get_env(:custode, :profiles, %{})

  defp apply_profile(routine) do
    profile = Map.get(profiles(), routine[:profile], %{})
    tags = Enum.uniq(Map.get(profile, :tags, []) ++ Map.get(routine, :tags, []))

    profile
    |> Map.merge(routine)
    |> Map.put(:tags, tags)
    |> Map.delete(:profile)
    |> template_approved_args()
  end

  # "custode-{id}" in a profile's approved_args becomes "custode-<routine id>"
  defp template_approved_args(%{approved_args: args} = routine) when is_map(args) do
    id = Map.fetch!(routine, :id)

    templated =
      Map.new(args, fn
        {key, value} when is_binary(value) -> {key, String.replace(value, "{id}", id)}
        pair -> pair
      end)

    %{routine | approved_args: templated}
  end

  defp template_approved_args(routine), do: routine

  @doc "The routine with this id, or nil."
  def get(id), do: Enum.find(all(), &(&1.id == id))

  @doc "The first configured routine (the default target for the console)."
  def default, do: hd(all())

  @doc """
  The static Oban Cron crontab: one entry per configured sensor plus the
  daily janitor (plain workers on the `:sensors` queue; see
  `Custode.Sensors.ContributorSearch`).

  Routines are NOT here anymore. `Custode.Scheduler` owns routine firing so a
  cron edit takes effect at the next minute with no restart (#142); the static
  plugin only reads its crontab once, at boot. Sensors and the janitor change
  rarely, so they stay boot-baked in the plugin.
  """
  def crontab do
    sensor_entries =
      for sensor <- sensors() do
        args = Map.merge(%{"sensor_id" => sensor.id, "notify" => sensor.notify}, sensor.args)
        {sensor.cron, sensor.module, args: args, queue: :sensors}
      end

    janitor_entries = [{"@daily", Custode.Janitor, args: %{}, queue: :sensors}]

    # advisors (#125) ride the same static lane as the janitor: always-on,
    # deterministic, zero tokens -- one daily look at the fleet's economics
    advisor_entries = [
      {"@daily", Custode.Advisors.Cadence, args: %{}, queue: :sensors},
      {"@daily", Custode.Advisors.Model, args: %{}, queue: :sensors},
      {"@daily", Custode.Advisors.Budget, args: %{}, queue: :sensors}
    ]

    sensor_entries ++ janitor_entries ++ advisor_entries
  end

  @doc """
  Boot-time guarantee: every routine's workspace (and its inbox/) exists
  before any turn can run. The quakes routine failed its first beats with
  command_failed because claude's working_dir did not exist yet -- every
  earlier workspace predated the config, so the assumption was invisible.
  A missing working_dir that is NOT the workspace (a repo checkout) is only
  warned about: creating an empty directory where a checkout should be
  would send an agent into a void.
  """
  def ensure_workspaces! do
    for routine <- all() do
      routine.workspace |> Path.expand() |> Path.join("inbox") |> File.mkdir_p!()

      working_dir = Path.expand(routine.working_dir)

      unless File.dir?(working_dir) do
        require Logger

        Logger.warning(
          "routine #{routine.id}: working_dir #{working_dir} does not exist; " <>
            "its turns will fail with command_failed until it does"
        )
      end
    end

    :ok
  end

  @doc "Configured sensors plus the ones derived from routine profiles."
  def sensors do
    configured =
      for sensor <- Application.get_env(:custode, :sensors, []) do
        %{
          id: Map.fetch!(sensor, :id),
          cron: Map.fetch!(sensor, :cron),
          module: Map.fetch!(sensor, :module),
          notify: Map.fetch!(sensor, :notify),
          args: Map.get(sensor, :args, %{})
        }
      end

    configured ++ derived_sensors()
  end

  # a profile saying sensors: [:ci] gives every repo-tied routine wearing it
  # a CI poll -- the sensor entry is derivation, not configuration
  defp derived_sensors do
    for routine <- all(), :ci in routine.sensors, is_binary(routine.repo) do
      %{
        id: "ci-" <> routine.id,
        cron: "*/15 * * * *",
        module: Custode.Sensors.CiStatus,
        notify: routine.id,
        args: %{repo: routine.repo}
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
  def sub_agent_args(workspace, opts) do
    ObanClaude.Args.defaults(
      model: opts[:model] || Application.fetch_env!(:custode, :model),
      working_dir: Path.expand(workspace),
      permission_mode: :accept_edits,
      max_turns: 20,
      max_budget_usd: Application.fetch_env!(:custode, :max_budget_usd),
      timeout: 200_000,
      json_schema: directive_schema(),
      # the memory-only MCP server: persistence without delegation powers;
      # the per-sub-agent config carries its minted identity token
      mcp_config: [Map.fetch!(opts, :mcp_config_path)],
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
        do: [mcp_config: Custode.MCP.config_paths(routine.id)],
        else: []

    extra = if allowed == [], do: extra, else: Keyword.put(extra, :allowed_tools, allowed)

    extra =
      if routine.hermetic != nil,
        do: Keyword.put(extra, :hermetic, routine.hermetic),
        else: extra

    extra =
      if routine.effort != nil,
        do: Keyword.put(extra, :effort, String.to_existing_atom(routine.effort)),
        else: extra

    extra =
      if routine.agent != nil,
        do: Keyword.put(extra, :agent, routine.agent),
        else: extra

    ObanClaude.Args.defaults(base ++ extra)
  end

  # Policies (#50) append to EVERY prompt, including operator-supplied
  # system_prompt: overrides -- fleet law rides along regardless of role.
  # Presence (#141) and repo-owned ambient orders (#19) ride the same way:
  # composed at tick time, so a presence flip or an edit to the working_dir's
  # .custode/orders.md reaches the very next sweep with no restart (#121/#142).
  defp system_prompt(%{mcp: true} = routine) do
    routine.system_prompt <>
      delegation_prompt() <>
      Custode.Policy.render(routine) <>
      Custode.Presence.render() <> Custode.Ambient.render(routine)
  end

  defp system_prompt(routine) do
    routine.system_prompt <>
      Custode.Policy.render(routine) <>
      Custode.Presence.render() <> Custode.Ambient.render(routine)
  end

  # Tool tiers (issue #40): the operator verbs (pause a sibling, beat a
  # routine, read the fleet) belong to the meta-agent only. Every other
  # mcp: true routine gets delegation over its OWN sub-agents plus its
  # notebook and memory. Allowlist-deep, not identity-deep (that is #2) --
  # but it removes the casual path to a backlog worker pausing the fleet.
  @worker_mcp_tools ~w(
    list_routines agent_status start_agent prompt_agent await_agent
    agent_history approve_action reject_action run_job
    journal_append compact_journal todo_add todo_list todo_complete inbox_list inbox_mark_filed
    remember recall forget
    repo_open_pr repo_open_issue repo_comment repo_ready_pr repo_merge_pr
    repo_mark_issue_ready repo_mark_issue_blocked repo_review_pr
    repo_list_issues repo_view_issue repo_list_prs repo_view_pr
    repo_pr_checks repo_pr_diff
  )

  # set_presence is deliberately absent: whether a human is around is the
  # human's own claim (or inference from their actions), never an agent's
  @operator_mcp_tools ~w(
    beat drop_note list_gates feed_tail pause_agent resume_agent spend_today
    preview_routine add_routine preview_routine_edit update_routine
    remove_routine
    preview_profile define_profile preview_profile_edit update_profile
    remove_profile
  )

  # The tool bundle follows the role's tier in the hierarchy (Custode.Roles):
  # the :custode tier (the fleet agent) also gets the operator tools; every
  # specialist gets the worker set. The permission model IS the hierarchy.
  defp mcp_allowlist(role) do
    operator = if Custode.Roles.grants(role) == :operator, do: @operator_mcp_tools, else: []
    prefix(@worker_mcp_tools ++ operator ++ optional_tools())
  end

  defp prefix(tools), do: Enum.map(tools, &("mcp__custode__" <> &1))

  # set_panel is verb-gated on the panels mode (#100): :off removes it from
  # every allowlist entirely, so an agent cannot even propose a panel.
  defp optional_tools do
    if Custode.Panels.mode() == :off, do: [], else: ["set_panel"]
  end

  @doc """
  Normalize a single raw entry outside the roster -- the validation seam for
  config write-back (design 001 slice 2): an entry that survives this will
  survive the roster. Raises on a broken entry, exactly like boot would.
  """
  def normalize_entry(routine), do: normalize(routine)

  defp normalize(routine) do
    routine = apply_profile(routine)
    id = Map.fetch!(routine, :id)
    workspace = Map.get(routine, :workspace, "workspaces/" <> id)
    # Least privilege by default (#161): a roster entry that FORGETS role
    # gets the powerless :assistant, never the caretaker's operator verbs.
    # The fleet's actual caretaker says role: :caretaker out loud.
    role = Map.get(routine, :role, :assistant)

    %{
      id: id,
      cron: Map.fetch!(routine, :cron),
      # :workspace is the notebook home (inbox/, rendered journal.md/TODO.md);
      # :working_dir is where claude runs. They coincide for a plain
      # caretaker; a repo caretaker runs at the repo root while its notebook
      # lives in a subdirectory. Relative paths root under Custode.Home
      # (#41 slice 5): cwd in source-repo mode, $CUSTODE_HOME installed.
      workspace: Custode.Home.resolve_in(&Custode.Home.data_dir/0, workspace),
      working_dir:
        Custode.Home.resolve_in(
          &Custode.Home.data_dir/0,
          Map.get(routine, :working_dir, workspace)
        ),
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
      # reasoning effort for SWEEPS (approved_args may raise it for
      # implementations); nil leaves the CLI default
      effort: Map.get(routine, :effort),
      system_prompt: resolve_prompt(routine, role, id),
      # non-hermetic runs inherit the repo's own CLAUDE.md/persona (#19);
      # set hermetic: true to shut ambient context out for a routine
      hermetic: Map.get(routine, :hermetic),
      # persona-by-name from the repo's own .claude/agents/ (#19): the repo
      # owns its worker's voice; nil runs claude as itself
      agent: Map.get(routine, :agent),
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
      # implied sensors from the profile (e.g. [:ci] derives a ci-<id>
      # CiStatus poll for the routine's repo -- see derived_sensors/0)
      sensors: Map.get(routine, :sensors, []),
      mcp: Map.get(routine, :mcp, false)
    }
  end

  defp default_prompt(role, id), do: Prompts.for_role(role, id)

  # #19: a routine may own its standing orders as a FILE (versioned prose,
  # editable without recompiling) -- charter still composes in front so
  # fleet law rides along.
  defp resolve_prompt(routine, role, id) do
    case Map.get(routine, :system_prompt_file) do
      nil ->
        Map.get(routine, :system_prompt, default_prompt(role, id))

      path ->
        Prompts.charter(id, role) <> "
" <> File.read!(path)
    end
  end

  defp directive_schema do
    Jason.encode!(%{
      type: "object",
      additionalProperties: false,
      required: ["directive", "summary"],
      properties: %{
        directive: %{type: "string", enum: ["none", "ask_user", "request_permission"]},
        summary: %{type: "string", description: "one-line sweep report"},
        question: %{type: "string", description: "set when directive=ask_user"},
        action: %{type: "string", description: "set when directive=request_permission"},
        # The schema'd epilogue (#120 slice 2): what the sweep touched, as
        # numbers rather than prose, so the feed and metrics read fields
        # instead of parsing the summary. Both stay optional -- a sweep that
        # touched nothing omits them.
        prs: %{
          type: "array",
          items: %{type: "integer"},
          description: "PR numbers this sweep opened, pushed to, or acted on"
        },
        issues_touched: %{
          type: "array",
          items: %{type: "integer"},
          description: "issue numbers this sweep worked, commented on, or judged"
        }
      }
    })
  end

  defp sub_agent_prompt, do: Prompts.sub_agent()

  defp delegation_prompt, do: Prompts.delegation()
end
