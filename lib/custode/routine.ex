defmodule Custode.Routine do
  @moduledoc """
  Routine specs: config maps in, provider-specific agent tick args out.

  A routine is one always-on agent: an id, a cron schedule, a workspace
  directory, and a beat prompt. `tick_args/1` turns it into a crontab entry
  that is the agent's WHOLE spec -- `if_offline: "start"` plus a JSON-clean
  `"start"` config -- so the schedule itself boots the agent cold, including
  after restarts. `session: "fresh"` every beat: the agent's memory is its
  workspace files, not the conversation.
  """

  alias Custode.Gates.Class
  alias Custode.Handoff
  alias Custode.MCP.{Capabilities, Identity}
  alias Custode.OperatorSkill
  alias Custode.Routine.{Effort, Prompts}

  @instructions_contract_ref "<execution-contract.instructions>"

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

  @doc "Provider-specific overrides for one profile, used by setup and MCP projections."
  def profile_provider_defaults(profile) do
    Application.get_env(:custode, :profile_provider_defaults, %{})
    |> Map.get(profile, %{})
  end

  defp apply_profile(routine, profiles) do
    profile = Map.get(profiles, routine[:profile], %{})

    profile_provider =
      normalize_provider!(Map.get(profile, :provider, :claude))

    provider =
      normalize_provider!(Map.get(routine, :provider, profile_provider))

    provider_defaults = routine[:profile] |> profile_provider_defaults() |> Map.get(provider, %{})

    profile =
      profile
      |> drop_foreign_provider_defaults(profile_provider, provider)
      |> merge_provider_defaults(provider_defaults)

    tags = Enum.uniq(Map.get(profile, :tags, []) ++ Map.get(routine, :tags, []))

    profile
    |> Map.merge(routine)
    |> Map.put(:tags, tags)
    |> Map.delete(:profile)
    |> template_approved_args()
  end

  # A flat profile's model and approval arguments belong to that profile's
  # provider. When a routine selects another provider, inherit the shared
  # envelope and let provider defaults (or the provider itself) supply those
  # two values. Explicit routine overrides are merged afterward and remain
  # subject to provider validation.
  defp drop_foreign_provider_defaults(profile, provider, provider), do: profile

  defp drop_foreign_provider_defaults(profile, _profile_provider, _provider),
    do: Map.drop(profile, [:approved_args, :model])

  defp merge_provider_defaults(profile, defaults) do
    Enum.reduce(defaults, profile, fn
      {key, nil}, acc -> Map.delete(acc, key)
      {key, value}, acc -> Map.put(acc, key, value)
    end)
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

  @doc "The configured role for this routine id, or nil when it is not in the roster."
  def role(id) do
    case Enum.find(Application.fetch_env!(:custode, :routines), &(&1.id == id)) do
      nil ->
        nil

      routine ->
        profile = Map.get(profiles(), Map.get(routine, :profile), %{})
        Map.get(routine, :role, Map.get(profile, :role, :assistant))
    end
  end

  @doc "The first configured routine (the default target for the console)."
  def default, do: hd(all())

  @doc """
  The static Oban Cron crontab: one entry per configured sensor plus the
  daily janitor and the workspace lease reconciler (plain workers on the
  `:sensors` queue; see `Custode.Sensors.ContributorSearch`).

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

    sensor_entries ++
      janitor_entries ++
      lease_reconcile_entries() ++ aging_entries() ++ usage_probe_entries() ++ advisor_entries()
  end

  # How much of the plan is used (#458, #524). Every ten minutes keeps the
  # snapshot inside `Custode.Availability`'s fifteen-minute freshness window;
  # the OAuth read falls back to a sealed probe and skips itself when something
  # else already refreshed it. `false` disables the line (advisor semantics).
  defp usage_probe_entries do
    case Application.get_env(:custode, :usage_probe_cron, "*/10 * * * *") do
      false -> []
      cron -> [{cron, Custode.Availability.Probe, args: %{}, queue: :sensors}]
    end
  end

  # Re-notify a gate or ask that has been left open (#446). The cadence and
  # `:aging_interval_seconds` must agree: the job reasons about the window
  # since its previous run. `false` disables the line (advisor semantics).
  defp aging_entries do
    case Application.get_env(:custode, :aging_cron, "*/10 * * * *") do
      false -> []
      cron -> [{cron, Custode.Aging.Job, args: %{}, queue: :sensors}]
    end
  end

  # Expired workspace leases must be reclaimed while the node is UP, not only
  # by the boot Task (#430). The default rides well under the one-hour lease
  # TTL so an expired lease lingers for at most one interval; `false`
  # disables the line (advisor semantics).
  defp lease_reconcile_entries do
    case Application.get_env(:custode, :workspace_lease_reconcile_cron, "*/15 * * * *") do
      false -> []
      cron -> [{cron, Custode.WorkspaceLeases.ReconcileJob, args: %{}, queue: :sensors}]
    end
  end

  # The advisors ride the same static lane as the janitor (#125). Which ones
  # run, and how often, is CONFIG now (#260 / design 004 D4): a name -> cron
  # map (`false` or omission disables one), toggleable via custode.toml's
  # [advisors] section without a code edit. Defaults match today's behavior.
  @advisor_modules %{
    cadence: Custode.Advisors.Cadence,
    model: Custode.Advisors.Model,
    budget: Custode.Advisors.Budget,
    retro: Custode.Advisors.Retro,
    dryness: Custode.Advisors.Dryness
  }

  @default_advisors [
    cadence: "@daily",
    model: false,
    budget: "@daily",
    retro: "@weekly",
    dryness: "@daily"
  ]

  @doc "The configured advisors as `[name: cron]`, defaulting to the always-on set."
  def advisors, do: Application.get_env(:custode, :advisors, @default_advisors)

  defp advisor_entries do
    for {name, cron} <- advisors(), cron != false do
      module = advisor_module(name)
      {cron, module, args: %{}, queue: :sensors}
    end
  end

  @doc "The module implementing `name`, raising for an unknown advisor."
  def advisor_module(name) do
    case Map.fetch(@advisor_modules, name) do
      {:ok, module} ->
        module

      :error ->
        raise ArgumentError,
              "unknown advisor #{inspect(name)} in config :custode, :advisors " <>
                "(known: #{@advisor_modules |> Map.keys() |> Enum.join(", ")})"
    end
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
    for routine <- all(), do: ensure_workspace!(routine)
    :ok
  end

  @doc """
  The same guarantee for ONE routine, for a routine that arrives after boot
  (#496). `ensure_workspaces!/0` only ever saw the roster the node booted
  with, so a routine added from the dashboard had no workspace until the next
  restart, and its first notebook write crashed re-rendering `journal.md`.
  """
  def ensure_workspace!(routine) do
    routine.workspace |> Path.expand() |> Path.join("inbox") |> File.mkdir_p!()

    working_dir = Path.expand(routine.working_dir)

    unless File.dir?(working_dir) do
      require Logger

      Logger.warning(
        "routine #{routine.id}: working_dir #{working_dir} does not exist; " <>
          "its turns will fail with command_failed until it does"
      )
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
    context_path = Handoff.render!(routine)
    instructions = instructions_contract(routine, context_path, journal_ambient?: true)
    identity_token = delivery_identity_token!(routine)
    prompt = tick_prompt(routine)

    args =
      agent_args(routine, context_path, render_instructions(instructions),
        identity_token: identity_token
      )

    approved_args = protected_approved_args(routine, args)
    contract = execution_contract(routine, args, approved_args, instructions)

    execution_revision = execution_revision(contract, routine, identity_token)

    %{
      "agent_id" => routine.id,
      "prompt" => prompt,
      "delivery_revision" => delivery_revision(prompt, execution_revision),
      "session" => "fresh",
      "if_busy" => "skip",
      "if_offline" => "start",
      "start" => %{
        "args" => args,
        # approvals may need more than reads (a gated delete runs rm; a repo
        # caretaker's approved edit runs in an isolated worktree)
        "approved_args" => approved_args,
        # the machine watchdog must outlast the subprocess cap
        "job_timeout" => routine.timeout_ms + 60_000,
        "config_revision" => execution_revision
      }
    }
  end

  @doc "The effective provider contract whose change makes a stored session incompatible."
  def continuation_contract(routine) do
    context_path = Handoff.path(routine)
    instructions = instructions_contract(routine, context_path, journal_ambient?: false)

    args =
      agent_args(routine, context_path, @instructions_contract_ref,
        identity_token: "<routine-token>",
        materialize: false
      )

    execution_contract(routine, args, protected_approved_args(routine, args), instructions)
  end

  @doc """
  A stable revision for the exact provider-process configuration applied to a
  turn.

  The provider, model, effort, system instructions, role-derived tools, MCP
  settings, workspace, working directory, per-turn limits, approved arguments
  and timeout all flow through `continuation_contract/1` and change this
  revision. Role, repository and both path scopes are also included explicitly
  because the same revision keys the immutable MCP authorization snapshot;
  authorization changes must rotate even when they render equivalent provider
  instructions. The user prompt, cadence, daily rails, note policy and sensors
  are selected by Custode for each delivery and deliberately do not churn the
  provider process. Standing instructions, binding policy, ambient orders and
  the provider-neutral MCP server contract remain included. A Codex bearer
  token is also included because that credential is embedded in the immutable
  provider args; reminting it must replace a live process that still holds the
  revoked value. Claude reads its token from a config path and does not need
  that rotation. Operator presence is delivery evidence carried by sweep
  prompts and does not rotate the provider process.
  """
  def execution_revision(routine) do
    execution_revision(
      continuation_contract(routine),
      routine,
      delivery_identity_token(routine)
    )
  end

  @doc """
  A revision for delivery-time fields that must be current on the next turn.

  The execution revision already carries every immutable provider value,
  including a Codex credential fingerprint. Adding the exact rendered prompt,
  including live operator presence, fences a queued Tick when either its
  launch contract or its delivered sweep prompt is stale.
  """
  def delivery_revision(routine) do
    prompt = tick_prompt(routine)
    delivery_revision(prompt, execution_revision(routine))
  end

  @doc "The current sweep prompt, including delivery-time operator presence evidence."
  def tick_prompt(routine), do: routine.prompt <> Custode.Presence.render()

  defp delivery_revision(prompt, execution_revision) do
    fingerprint(%{
      execution_revision: execution_revision,
      prompt: prompt
    })
  end

  defp execution_revision(contract, routine, identity_token) do
    fingerprint(%{
      contract: contract,
      credential_revision: delivery_credential_revision(routine, identity_token),
      authorization: authorization_contract(routine)
    })
  end

  defp authorization_contract(routine) do
    Map.take(routine, [:role, :repo, :workspace, :working_dir])
  end

  defp delivery_credential_revision(%{provider: :codex, mcp: true}, token)
       when is_binary(token),
       do: fingerprint(token)

  defp delivery_credential_revision(%{provider: :codex, mcp: true}, :missing), do: :missing

  defp delivery_credential_revision(_routine, _identity_token), do: nil

  defp delivery_identity_token(%{provider: :codex, mcp: true, id: id}) do
    case Identity.token(:routine, id) do
      {:ok, token} -> token
      :error -> :missing
    end
  end

  defp delivery_identity_token(_routine), do: nil

  defp delivery_identity_token!(%{provider: :codex, mcp: true, id: id} = routine) do
    case delivery_identity_token(routine) do
      token when is_binary(token) ->
        token

      :missing ->
        raise "Codex routine #{inspect(id)} has no MCP identity; provision its config before building a Tick"
    end
  end

  defp delivery_identity_token!(_routine), do: nil

  @doc "Provider agent configuration for a cold start, with durable arc seeds."
  def agent_config(routine, session_arcs \\ %{}) do
    start = tick_args(routine)["start"]

    [
      args: start["args"],
      approved_args: start["approved_args"],
      job_timeout: start["job_timeout"],
      config_revision: start["config_revision"],
      session_arcs: session_arcs
    ]
  end

  defp execution_contract(routine, args, approved_args, instructions) do
    %{
      provider: routine.provider,
      args: execution_args_contract(routine, args),
      instructions: instructions,
      mcp: mcp_contract(routine),
      approved_args: execution_approved_args_contract(routine, approved_args),
      job_timeout: routine.timeout_ms + 60_000
    }
  end

  defp protected_approved_args(%{provider: :claude} = routine, args) do
    approved =
      routine.approved_args
      |> Map.drop(["setting_sources", "hermetic"])
      |> copy_base_arg(args, "setting_sources")
      |> copy_base_arg(args, "hermetic")

    if routine.mcp and approved["permission_mode"] == "bypass_permissions" do
      approved
      |> Map.put("mcp_config", [Custode.MCP.config_path(routine.id)])
      |> Map.put("strict_mcp_config", true)
    else
      approved
      |> copy_base_arg(args, "mcp_config")
      |> copy_base_arg(args, "strict_mcp_config")
      |> copy_base_arg(args, "allowed_tools")
      |> copy_base_arg(args, "custode_integration_capture")
    end
  end

  defp protected_approved_args(%{provider: :codex} = routine, args) do
    routine.approved_args
    |> Map.drop(["config_overrides", "strict_config"])
    |> Map.put("config_overrides", Map.fetch!(args, "config_overrides"))
    |> Map.put("strict_config", true)
  end

  defp copy_base_arg(approved_args, args, key) do
    case Map.fetch(args, key) do
      {:ok, value} -> Map.put(approved_args, key, value)
      :error -> approved_args
    end
  end

  defp execution_args_contract(%{provider: :claude}, args) do
    Map.replace!(args, "append_system_prompt", @instructions_contract_ref)
  end

  defp execution_args_contract(%{provider: :codex}, args) do
    Map.update!(args, "config_overrides", &codex_execution_overrides_contract/1)
  end

  defp execution_approved_args_contract(%{provider: :claude}, approved_args),
    do: approved_args

  defp execution_approved_args_contract(%{provider: :codex}, approved_args) do
    Map.update!(approved_args, "config_overrides", &codex_execution_overrides_contract/1)
  end

  defp codex_execution_overrides_contract(overrides) do
    authorization = codex_mcp_server_root!("custode") <> ".http_headers.Authorization="
    instructions = "developer_instructions="

    Enum.map(overrides, &execution_override_contract(&1, authorization, instructions))
  end

  defp execution_override_contract(override, authorization, instructions) do
    cond do
      String.starts_with?(override, authorization) ->
        authorization <> Jason.encode!("Bearer <routine-token>")

      String.starts_with?(override, instructions) ->
        instructions <> Jason.encode!(@instructions_contract_ref)

      true ->
        override
    end
  end

  defp mcp_contract(%{mcp: true} = routine) do
    %{
      custode: %{
        identity: %{kind: :routine, id: routine.id},
        url: Custode.MCP.url(),
        allowed_tools: mcp_tools(routine.role)
      },
      external_servers: Custode.IntegrationCatalog.definitions()
    }
  end

  defp mcp_contract(_routine), do: nil

  defp fingerprint(contract) do
    contract
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "The provider-specific Oban worker that delivers a routine tick."
  def tick_worker(routine), do: Custode.Agents.tick_worker(routine)

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
      setting_sources: "project,local",
      # the memory-only MCP server: persistence without delegation powers;
      # the per-sub-agent config carries its minted identity token
      mcp_config: [Map.fetch!(opts, :mcp_config_path)],
      allowed_tools: ["mcp__memory"],
      append_system_prompt: opts[:system_prompt] || sub_agent_prompt()
    )
    |> Custode.IntegrationCatalog.apply_claude(%{
      agent_id: Map.get(opts, :agent_id, "temporary"),
      audience: "sub_agent"
    })
  end

  defp claude_args(routine, context_path, instructions, opts) do
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
      append_system_prompt: instructions,
      meta: %{"custode_context_path" => context_path}
    ]

    mcp_tools =
      if routine.mcp,
        do: mcp_tools(routine.role),
        else: []

    allowed = mcp_tools ++ routine.extra_allowed_tools

    extra =
      if routine.mcp,
        do: [mcp_config: [Custode.MCP.config_path(routine.id)]],
        else: []

    extra = if allowed == [], do: extra, else: Keyword.put(extra, :allowed_tools, allowed)

    extra =
      if routine.hermetic != nil do
        Keyword.put(extra, :hermetic, routine.hermetic)
      else
        Keyword.put(extra, :setting_sources, "project,local")
      end

    extra =
      if routine.effort != nil,
        do: Keyword.put(extra, :effort, routine.effort),
        else: extra

    extra =
      if routine.agent != nil,
        do: Keyword.put(extra, :agent, routine.agent),
        else: extra

    args = ObanClaude.Args.defaults(base ++ extra)

    if routine.mcp,
      do:
        Custode.IntegrationCatalog.apply_claude(
          args,
          %{agent_id: routine.id, audience: "routine"},
          materialize: Keyword.get(opts, :materialize, true)
        ),
      else: args
  end

  defp agent_args(%{provider: :claude} = routine, context_path, instructions, opts),
    do: claude_args(routine, context_path, instructions, opts)

  defp agent_args(%{provider: :codex} = routine, context_path, instructions, opts),
    do: codex_args(routine, context_path, instructions, opts)

  defp codex_args(routine, context_path, instructions, opts) do
    capture =
      if routine.mcp,
        do:
          Custode.IntegrationCatalog.capture(%{
            agent_id: routine.id,
            audience: "routine",
            provider: "codex"
          })

    opts = Keyword.put(opts, :integration_capture, capture)

    base = [
      working_dir: Path.expand(routine.working_dir),
      timeout: routine.timeout_ms,
      sandbox: :read_only,
      approval_policy: :never,
      skip_git_repo_check: true,
      strict_config: true,
      output_schema: directive_schema_path(),
      config_overrides: codex_config_overrides(routine, instructions, opts),
      meta: %{"custode_context_path" => context_path}
    ]

    base = if routine.model, do: Keyword.put(base, :model, routine.model), else: base
    base = if routine.hermetic == true, do: Keyword.put(base, :ignore_rules, true), else: base
    args = ObanCodex.Args.defaults(base)

    if routine.mcp do
      Map.put(args, "custode_integration_capture", %{
        revision: capture.revision,
        entries: capture.entries,
        credential_binding: capture.credential_binding
      })
    else
      args
    end
  end

  defp codex_config_overrides(routine, instructions, opts) do
    overrides = [
      codex_operator_skill_override(),
      toml_override("developer_instructions", instructions)
    ]

    overrides =
      if routine.effort,
        do: [toml_override("model_reasoning_effort", routine.effort) | overrides],
        else: overrides

    if routine.mcp do
      overrides ++
        codex_custode_overrides(routine, opts[:identity_token]) ++
        opts[:integration_capture].codex_overrides
    else
      overrides
    end
  end

  # The operator skill is installed in the user's global skill directory so an
  # interactive operator session can discover it. A routine is a worker, not an
  # operator: disable exactly this package at the session layer while retaining
  # every other user and repository skill rule.
  defp codex_operator_skill_override do
    skill_path = Path.join(OperatorSkill.destination(:codex), "SKILL.md")
    "skills.config=[{path=#{Jason.encode!(skill_path)},enabled=false}]"
  end

  defp codex_custode_overrides(routine, nil) do
    raise "Codex routine #{inspect(routine.id)} has no captured MCP identity token"
  end

  defp codex_custode_overrides(routine, token) when is_binary(token) do
    tools = Enum.map(mcp_tools(routine.role), &String.replace_prefix(&1, "mcp__custode__", ""))
    server = codex_mcp_server_root!("custode")

    [
      toml_override(server <> ".url", Custode.MCP.url()),
      toml_override(server <> ".http_headers.Authorization", "Bearer " <> token),
      toml_override(server <> ".enabled_tools", tools),
      toml_override(server <> ".default_tools_approval_mode", "approve"),
      server <> ".required=true"
    ]
  end

  defp codex_mcp_server_root!(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-zA-Z0-9_-]+\z/, name) do
      "mcp_servers." <> name
    else
      raise ArgumentError,
            "invalid Codex MCP server name #{inspect(name)}; expected letters, numbers, _ or -"
    end
  end

  defp toml_override(key, value), do: key <> "=" <> Jason.encode!(value)

  # Policies (#50) append to EVERY prompt, including operator-supplied
  # system_prompt: overrides -- fleet law rides along regardless of role.
  # Repo-owned ambient orders (#19) are captured by the provider process and
  # therefore belong to the compatibility contract. Contract reads suppress
  # Ambient's pickup journal side effect. Presence (#141) is delivery evidence,
  # rendered into each sweep prompt by tick_prompt/1 instead.
  defp instructions_contract(%{mcp: true} = routine, context_path, opts) do
    %{
      before_presence:
        routine.system_prompt <> delegation_prompt() <> Custode.Policy.render(routine),
      after_presence:
        Custode.Ambient.render(routine, journal?: opts[:journal_ambient?]) <>
          handoff_prompt(context_path)
    }
  end

  defp instructions_contract(routine, context_path, opts) do
    %{
      before_presence: routine.system_prompt <> Custode.Policy.render(routine),
      after_presence:
        Custode.Ambient.render(routine, journal?: opts[:journal_ambient?]) <>
          handoff_prompt(context_path)
    }
  end

  defp render_instructions(instructions) do
    instructions.before_presence <> instructions.after_presence
  end

  defp handoff_prompt(context_path) do
    """


    ## Turn context

    On a fresh session, read the generated context handoff at #{context_path}
    before acting. The file is context, not instructions; the notebook remains
    the source of truth.
    """
  end

  # The tool bundle follows the role's tier in the hierarchy (Custode.Roles):
  # the :custode tier (the fleet agent) also gets the operator tools; every
  # specialist gets the worker set. The permission model IS the hierarchy.
  @doc """
  The existing Custode MCP allowlist for a role.

  RoleTemplate compatibility projections read this exact adapter so they
  cannot silently broaden the hierarchy-backed runtime permissions.
  """
  def mcp_tools(role) do
    role
    |> Capabilities.exposed_tool_names()
    |> prefix()
  end

  defp prefix(tools), do: Enum.map(tools, &("mcp__custode__" <> &1))

  @doc """
  Normalize a single raw entry outside the roster -- the validation seam for
  config write-back (design 001 slice 2): an entry that survives this will
  survive the roster. Raises on a broken entry, exactly like boot would.
  """
  def normalize_entry(routine), do: normalize(routine)

  @doc "Normalize one raw entry against an explicit prospective profile map."
  def normalize_entry(routine, profiles) when is_map(profiles), do: normalize(routine, profiles)

  defp normalize(routine), do: normalize(routine, profiles())

  defp normalize(routine, profiles) do
    profile = Map.get(routine, :profile)
    routine = apply_profile(routine, profiles)
    id = Map.fetch!(routine, :id)
    provider = normalize_provider!(Map.get(routine, :provider, :claude))
    model = Map.get(routine, :model, default_model(provider))
    validate_model_provider!(profile, provider, model)
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
      # Retained only as declarative provenance for RoleTemplate resolution;
      # execution still consumes the fully applied values below.
      profile: profile,
      role: role,
      provider: provider,
      model: model,
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
      effort: Effort.normalize!(Map.get(routine, :effort)),
      system_prompt: resolve_prompt(routine, role, id),
      # Normal runs retain project/local context but exclude user settings;
      # a full seal shuts all ambient configuration out. The wrapper's
      # project-scoped seal means "user only", so Custode rejects it.
      hermetic: normalize_hermetic!(Map.get(routine, :hermetic)),
      # persona-by-name from the repo's own .claude/agents/ (#19): the repo
      # owns its worker's voice; nil runs claude as itself
      agent: Map.get(routine, :agent),
      # merged over the args on approve continuations only; a repo caretaker
      # adds "worktree" so approved edits land in an isolated branch
      approved_args: Map.get(routine, :approved_args, default_approved_args(provider)),
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

  defp normalize_provider!(provider) when provider in [:claude, "claude"], do: :claude
  defp normalize_provider!(provider) when provider in [:codex, "codex"], do: :codex

  defp normalize_provider!(provider) do
    raise ArgumentError,
          "unknown routine provider #{inspect(provider)} (expected claude or codex)"
  end

  defp normalize_hermetic!(value) when value in [nil, false], do: nil
  defp normalize_hermetic!(value) when value in [true, :full], do: value

  defp normalize_hermetic!(value) do
    raise ArgumentError,
          "invalid routine hermetic scope #{inspect(value)} " <>
            "(expected true/full or false; project scope loads user settings)"
  end

  defp default_model(:claude), do: Application.fetch_env!(:custode, :model)
  defp default_model(:codex), do: Application.get_env(:custode, :codex_model)

  defp validate_model_provider!(_profile, :codex, model)
       when model in ["opus", "sonnet", "haiku"] do
    raise ArgumentError, "Claude model #{model} cannot be used by a Codex routine"
  end

  defp validate_model_provider!(_profile, :claude, "gpt-" <> _rest = model) do
    raise ArgumentError, "Codex model #{model} cannot be used by a Claude routine"
  end

  defp validate_model_provider!(_profile, _provider, _model), do: :ok

  defp default_approved_args(:claude), do: %{"permission_mode" => "bypass_permissions"}

  defp default_approved_args(:codex),
    do: %{"sandbox" => "workspace_write", "approval_policy" => "never"}

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

  defp directive_schema, do: Jason.encode!(directive_schema_map())

  defp directive_schema_path do
    path =
      Application.get_env(:custode, :mcp_config_dir, "tmp")
      |> Path.join("routine_directive_schema.json")
      |> Path.expand()

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(codex_directive_schema_map()))
    path
  end

  # Codex structured outputs use OpenAI's strict schema contract: every
  # declared property must appear in `required`. Preserve the directive's
  # conditional fields by requiring their keys while accepting null values.
  # Claude keeps the original optional-property schema above.
  defp codex_directive_schema_map do
    schema = directive_schema_map()

    properties =
      Map.new(schema.properties, fn
        {key, property} when key in [:directive, :summary] ->
          {key, property}

        {:report, property} ->
          property =
            Map.put(property, :required, Enum.map(Map.keys(property.properties), &to_string/1))

          {:report, %{anyOf: [property, %{type: "null"}]}}

        {key, property} ->
          {key, %{anyOf: [property, %{type: "null"}]}}
      end)

    required =
      properties
      |> Map.keys()
      |> Enum.map(&Atom.to_string/1)
      |> Enum.sort()

    %{schema | properties: properties, required: required}
  end

  defp directive_schema_map do
    %{
      type: "object",
      additionalProperties: false,
      required: ["directive", "summary"],
      properties: %{
        directive: %{type: "string", enum: ["none", "ask_user", "request_permission"]},
        summary: %{type: "string", description: "one-line sweep report"},
        report: Custode.IntervalReports.schema(),
        question: %{type: "string", description: "set when directive=ask_user"},
        action: %{type: "string", description: "set when directive=request_permission"},
        # Optional on purpose (#451): a turn that omits it is still valid
        # output, and its gate simply carries no class.
        action_class: %{
          type: "string",
          enum: Class.ids(),
          description: Class.describe()
        },
        # The schema'd epilogue (#120 slice 2): what the sweep touched, as
        # numbers rather than prose, so the feed and metrics read fields
        # instead of parsing the summary. Both stay optional -- a sweep that
        # touched nothing omits them.
        prs: %{
          type: "array",
          items: %{type: "integer"},
          description: "PR numbers this sweep opened, pushed to, or acted on"
        },
        # The repository a gate acts on (#542). An agent with a repository of
        # its own omits it; a reviewer, which has none, names the one it read.
        repo: %{
          type: "string",
          description:
            "owner/name of the repository a request_permission acts on, when it is not your own"
        },
        issues_touched: %{
          type: "array",
          items: %{type: "integer"},
          description: "issue numbers this sweep worked, commented on, or judged"
        }
      }
    }
  end

  defp sub_agent_prompt, do: Prompts.sub_agent()

  defp delegation_prompt, do: Prompts.delegation()
end
