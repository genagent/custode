defmodule Custode.ClaudeManagedSettings do
  @moduledoc """
  What an organization's managed Claude Code settings do to custode's Claude
  turns (#695), read from the files Claude Code reads. No claude call and no
  credential file: doctor runs this before anything paid happens.

  Two managed keys break a fleet without an error custode can see:

    * `allowManagedPermissionRulesOnly` -- Claude Code keeps only the managed
      policy's allow rules and drops the `--allowed-tools` list that
      `Custode.Routine` builds for each routine. A headless turn cannot
      prompt, so every tool the policy does not allow is denied.
    * `permissions.disableBypassPermissionsMode: "disable"` -- blocks the
      `bypass_permissions` mode that approved Claude continuations run in by
      default.

  The sources, highest rank first, are the server-managed cache
  (`remote-settings.json` in the Claude config directory) and the system
  file source (`managed-settings.json` merged with `managed-settings.d/*.json`).
  An MDM profile or a Windows registry value is not a file and is not read.
  Claude Code applies the first source that carries a policy key unless that
  source sets `managedSourcesBehavior: "merge"`; `policy/1` models both.
  """

  @server "mcp__custode"

  # Keys that steer how sources combine; a source carrying only these (or a
  # schema pointer) delivers no policy, and Claude Code moves on to the next.
  @control_keys ~w($schema managedSourcesBehavior wslInheritsWindowsSettings)

  @typedoc "One managed source: its settings (nil when absent) and read errors."
  @type source :: %{name: String.t(), settings: map() | nil, errors: [String.t()]}

  @typedoc "The policy Claude Code would apply, reduced to the keys doctor reads."
  @type policy :: %{
          applied: [String.t()],
          rules_only_by: [String.t()],
          bypass_disabled_by: [String.t()],
          allow: [term()],
          errors: [String.t()]
        }

  @doc """
  Read every managed source in rank order.

  Options, for tests and unusual installs: `:config_dir` (default
  `CLAUDE_CONFIG_DIR`, else `~/.claude`) and `:system_dir` (default the
  platform's managed settings directory).
  """
  @spec read(keyword()) :: [source()]
  def read(opts \\ []) do
    remote = Path.join(config_dir(opts), "remote-settings.json")
    system = Keyword.get_lazy(opts, :system_dir, &system_dir/0)

    [
      source("server-managed settings (#{remote})", [remote]),
      source("managed settings files (#{system})", file_paths(system))
    ]
  end

  @doc "Select and combine the sources Claude Code would apply."
  @spec policy([source()]) :: policy()
  def policy(sources) do
    delivering = Enum.filter(sources, &policy?(&1.settings))

    applied =
      case {delivering, behavior(sources)} do
        {[], _behavior} -> []
        {all, "merge"} -> all
        {[first | _rest], _first_wins} -> [first]
      end

    %{
      applied: Enum.map(applied, & &1.name),
      rules_only_by: names_where(applied, &(&1["allowManagedPermissionRulesOnly"] == true)),
      bypass_disabled_by:
        names_where(applied, &(permissions(&1)["disableBypassPermissionsMode"] == "disable")),
      allow: applied |> Enum.flat_map(&list(permissions(&1.settings)["allow"])) |> Enum.uniq(),
      errors: Enum.flat_map(sources, & &1.errors)
    }
  end

  @doc "The tools in `tools` that no allow rule in `policy` matches."
  @spec uncovered(policy(), [String.t()]) :: [String.t()]
  def uncovered(%{allow: allow}, tools) do
    matchers = Enum.flat_map(allow, &matcher/1)
    Enum.reject(tools, fn tool -> Enum.any?(matchers, &Regex.match?(&1, tool)) end)
  end

  @doc "Doctor's line for `allowManagedPermissionRulesOnly`, given custode's tool names."
  @spec describe_permission_rules(policy(), [String.t()]) :: String.t()
  def describe_permission_rules(%{applied: []} = policy, _tools), do: none(policy)

  def describe_permission_rules(%{rules_only_by: []} = policy, _tools),
    do:
      "#{sentence(policy.applied)} does not set allowManagedPermissionRulesOnly" <> notes(policy)

  def describe_permission_rules(policy, tools) do
    by = sentence(policy.rules_only_by) <> " sets allowManagedPermissionRulesOnly"

    case uncovered(policy, tools) do
      [] ->
        "#{by}; its allow rules cover all #{length(tools)} custode tools" <> notes(policy)

      missing ->
        coverage =
          if length(missing) == length(tools),
            do: "no managed allow rule matches the custode MCP server",
            else:
              "its allow rules cover #{length(tools) - length(missing)} of #{length(tools)} " <>
                "custode tools (not #{sample(missing)})"

        "warning: #{by} and #{coverage}. Claude Code ignores custode's --allowed-tools, so " <>
          "headless turns are denied every tool the managed policy does not allow; the " <>
          "organization's administrator can add a managed allow rule such as " <>
          "#{@server}__*" <> notes(policy)
    end
  end

  @doc "Doctor's line for `permissions.disableBypassPermissionsMode`."
  @spec describe_bypass(policy()) :: String.t()
  def describe_bypass(%{applied: []} = policy), do: none(policy)

  def describe_bypass(%{bypass_disabled_by: []} = policy),
    do: "#{sentence(policy.applied)} does not disable bypass permissions mode" <> notes(policy)

  def describe_bypass(policy) do
    "warning: #{sentence(policy.bypass_disabled_by)} sets " <>
      "permissions.disableBypassPermissionsMode to \"disable\", which blocks approved Claude " <>
      "continuations that run with bypass_permissions (the default approved_args)" <>
      notes(policy)
  end

  defp source(name, paths) do
    {settings, errors} = Enum.reduce(paths, {nil, []}, &read_json/2)
    %{name: name, settings: settings, errors: Enum.reverse(errors)}
  end

  defp read_json(path, {settings, errors}) do
    with {:ok, raw} <- File.read(path),
         {:ok, %{} = map} <- Jason.decode(raw) do
      {merge(settings || %{}, map), errors}
    else
      {:error, reason} when reason in [:enoent, :enotdir] -> {settings, errors}
      {:error, %Jason.DecodeError{}} -> {settings, ["#{path} is not valid JSON" | errors]}
      {:error, reason} -> {settings, ["#{path} is unreadable (#{reason})" | errors]}
      {:ok, _not_an_object} -> {settings, ["#{path} is not a JSON object" | errors]}
    end
  end

  # managed-settings.json first, then every non-hidden *.json drop-in in
  # alphabetical order, the order Claude Code merges them in.
  defp file_paths(system_dir) do
    drop_in_dir = Path.join(system_dir, "managed-settings.d")

    drop_ins =
      case File.ls(drop_in_dir) do
        {:ok, names} ->
          names
          |> Enum.filter(&(Path.extname(&1) == ".json" and not String.starts_with?(&1, ".")))
          |> Enum.sort()
          |> Enum.map(&Path.join(drop_in_dir, &1))

        {:error, _reason} ->
          []
      end

    [Path.join(system_dir, "managed-settings.json") | drop_ins]
  end

  # Claude Code's drop-in merge: a later single value replaces, lists union,
  # nested blocks merge key by key. Its whole-value exceptions (fallbackModel,
  # modelPicker and the named-entry maps) do not touch the keys read here.
  @doc false
  def merge(left, right) do
    Map.merge(left, right, fn
      _key, %{} = l, %{} = r -> merge(l, r)
      _key, l, r when is_list(l) and is_list(r) -> Enum.uniq(l ++ r)
      _key, _l, r -> r
    end)
  end

  # Read from the highest-ranked source that carries either the key or a
  # policy key, so a lower source cannot opt itself into merging.
  defp behavior(sources) do
    Enum.find_value(sources, "first-wins", fn %{settings: settings} ->
      cond do
        not is_map(settings) -> nil
        Map.has_key?(settings, "managedSourcesBehavior") -> settings["managedSourcesBehavior"]
        policy?(settings) -> "first-wins"
        true -> nil
      end
    end)
  end

  defp policy?(%{} = settings), do: settings |> Map.drop(@control_keys) |> map_size() > 0
  defp policy?(_absent), do: false

  defp names_where(sources, fun),
    do: for(%{settings: settings, name: name} <- sources, fun.(settings), do: name)

  defp permissions(%{"permissions" => %{} = permissions}), do: permissions
  defp permissions(_settings), do: %{}

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  # `mcp__custode` names every tool on the server. A glob only counts after
  # the literal server prefix, and settings files skip an mcp__ rule with
  # parentheses, so neither `mcp__*` nor `mcp__custode__x(...)` allows here.
  defp matcher(@server), do: [~r/^mcp__custode__/]

  defp matcher(rule) when is_binary(rule) do
    if String.starts_with?(rule, @server <> "__") and not String.contains?(rule, "(") do
      pattern = rule |> String.split("*") |> Enum.map_join(".*", &Regex.escape/1)
      [Regex.compile!("^" <> pattern <> "$")]
    else
      []
    end
  end

  defp matcher(_rule), do: []

  defp none(policy), do: "no managed settings found" <> notes(policy)

  defp notes(%{errors: []}), do: ""
  defp notes(%{errors: errors}), do: "; warning: " <> Enum.join(errors, "; ")

  defp sentence(names), do: Enum.join(names, " and ")

  defp sample(tools) do
    shown =
      tools
      |> Enum.take(3)
      |> Enum.map_join(", ", &String.replace_prefix(&1, @server <> "__", ""))

    if length(tools) > 3, do: shown <> ", ...", else: shown
  end

  defp config_dir(opts) do
    case Keyword.get_lazy(opts, :config_dir, fn -> System.get_env("CLAUDE_CONFIG_DIR") end) do
      dir when is_binary(dir) and dir != "" -> Path.expand(dir)
      _unset -> Path.join(System.user_home!(), ".claude")
    end
  end

  defp system_dir do
    case :os.type() do
      {:unix, :darwin} -> "/Library/Application Support/ClaudeCode"
      {:win32, _name} -> "C:\\Program Files\\ClaudeCode"
      {:unix, _name} -> "/etc/claude-code"
    end
  end
end
