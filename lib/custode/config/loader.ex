defmodule Custode.Config.Loader do
  @moduledoc """
  The routines.toml loader (#41 / design 001, slice 1).

  When a routines file exists it is the WHOLE routine+sensor roster and it
  wins outright -- the `config.exs` lists are ignored, never merged (D1:
  merging two sources is drift with extra steps). Without a file, nothing
  happens and the exs roster serves as before, which keeps the source-repo
  dev loop untouched.

  Resolution order for the file path:

    1. `$CUSTODE_CONFIG` (explicit, wins)
    2. `routines.toml` under `Custode.Home.root/0` (the cwd in source-repo
       mode, `$CUSTODE_HOME` in installed mode)

  `runtime.exs` calls `load/0` at boot and applies the roster via `config/2`;
  `load!/0` is the runtime-reload flavor (put_env on the live app) that the
  WriteBack path uses. Either way the entries land in the same atom-keyed
  shape the exs lists carry, and everything downstream still flows through
  `Custode.Routine.normalize/1`, the single choke point (D3).

  The file carries ASSIGNMENTS (D2): five-line id/profile/repo/working_dir/
  tags entries plus the optional per-routine overrides. Prompt bodies never
  live here; `system_prompt_file` references stay paths.

  TOML shape:

      [[routines]]
      id = "redisctl"
      profile = "backlog_worker"
      repo = "redis/redisctl"
      working_dir = "/Users/x/Code/github.com/redis/redisctl"
      tags = ["rust", "external"]

      [[sensors]]
      id = "ci-redisctl"
      cron = "*/15 * * * *"
      module = "CiStatus"
      notify = "redisctl"
      [sensors.args]
      repo = "redis/redisctl"

  Sensor `module` is the short name under `Custode.Sensors.*`, resolved with
  `Module.safe_concat/1` so a typo fails loudly at boot rather than at the
  first fire.
  """

  # Keys allowed on a routine entry, mapped to the atoms normalize/1 reads.
  # A key outside this list is a boot error: silently dropping an operator's
  # typo'd override would be config drift wearing a helpful face.
  @routine_keys %{
    "id" => :id,
    "cron" => :cron,
    "profile" => :profile,
    "workspace" => :workspace,
    "working_dir" => :working_dir,
    "repo" => :repo,
    "tags" => :tags,
    "prompt" => :prompt,
    "role" => :role,
    "model" => :model,
    "effort" => :effort,
    "agent" => :agent,
    "mcp" => :mcp,
    "hermetic" => :hermetic,
    "max_budget_usd" => :max_budget_usd,
    "daily_budget_usd" => :daily_budget_usd,
    "daily_budget_tokens" => :daily_budget_tokens,
    "timeout_ms" => :timeout_ms,
    "max_turns" => :max_turns,
    "system_prompt" => :system_prompt,
    "system_prompt_file" => :system_prompt_file,
    "extra_allowed_tools" => :extra_allowed_tools,
    "approved_args" => :approved_args
  }

  @sensor_keys %{
    "id" => :id,
    "cron" => :cron,
    "module" => :module,
    "notify" => :notify,
    "args" => :args
  }

  # Keys allowed on a PROFILE entry (#236): the envelope a routine inherits.
  # A superset of the routine overrides (minus id/profile, which are
  # instance-level) plus `sensors` (a profile derives per-routine sensors).
  # `name` is the map key, handled specially. Same loud-on-typo contract.
  @profile_keys %{
    "cron" => :cron,
    "prompt" => :prompt,
    "role" => :role,
    "mcp" => :mcp,
    "model" => :model,
    "effort" => :effort,
    "agent" => :agent,
    "workspace" => :workspace,
    "working_dir" => :working_dir,
    "hermetic" => :hermetic,
    "max_budget_usd" => :max_budget_usd,
    "daily_budget_usd" => :daily_budget_usd,
    "daily_budget_tokens" => :daily_budget_tokens,
    "timeout_ms" => :timeout_ms,
    "max_turns" => :max_turns,
    "tags" => :tags,
    "sensors" => :sensors,
    "system_prompt" => :system_prompt,
    "system_prompt_file" => :system_prompt_file,
    "extra_allowed_tools" => :extra_allowed_tools,
    "approved_args" => :approved_args
  }

  # values that are atoms in the exs shape and strings in TOML
  @atom_valued [:profile, :role, :effort]

  @doc """
  Find and parse the routines file. Returns `{:ok, path, routines, sensors}`
  or `:no_file`. Raises on a malformed file -- a bad roster should stop the
  boot, not quietly run yesterday's.

  `runtime.exs` consumes this via `config/2` (a `put_env` during config
  evaluation would be clobbered when the collected config applies).
  """
  def load do
    case file_path() do
      nil ->
        :no_file

      path ->
        {routines, sensors, profiles} = parse!(File.read!(path), path)
        {:ok, path, routines, sensors, profiles}
    end
  end

  @doc """
  Parse the file and apply it to the RUNNING application env. This is the
  runtime-reload path (design 001 D4: WriteBack calls this after appending an
  entry, making the edit live at the scheduler's next minute). Same return
  shape as `load/0`.
  """
  def load! do
    with {:ok, path, routines, sensors, profiles} <- load() do
      Application.put_env(:custode, :routines, routines)
      Application.put_env(:custode, :sensors, sensors)
      apply_profiles(profiles)
      {:ok, path, routines, sensors, profiles}
    end
  end

  @doc """
  Apply file-sourced profiles to the running env, but ONLY when the file
  actually declares any (#236). A file with a `[[profiles]]` section owns the
  profile map outright (D1) -- WriteBack.ensure_file! dumps the config.exs
  profiles into any file it creates, so a custode-written file always carries
  them. But a file with NO `[[profiles]]` section (every roster written before
  #236) means "I do not manage profiles here": applying its empty map would
  wipe the config.exs profiles every routine inherits from and crash the fleet
  on the next boot. So an empty parse falls through to the config defaults.
  """
  def apply_profiles(profiles) when map_size(profiles) > 0,
    do: Application.put_env(:custode, :profiles, profiles)

  def apply_profiles(_empty), do: :ok

  @doc """
  The path a write-back should target: `$CUSTODE_CONFIG` when set (whether or
  not the file exists yet -- the first write CREATES it there), else the cwd
  default. Contrast `file_path/0`, the READ resolution, where a set-but-absent
  `CUSTODE_CONFIG` is a loud error.
  """
  def target_path do
    case System.get_env("CUSTODE_CONFIG") do
      path when is_binary(path) and path != "" -> path
      _unset -> Custode.Home.resolve_in(&Custode.Home.config_dir/0, "routines.toml")
    end
  end

  @doc "The resolved routines file path, or nil when none is configured/present."
  def file_path do
    case System.get_env("CUSTODE_CONFIG") do
      path when is_binary(path) and path != "" ->
        if File.exists?(path),
          do: path,
          else: raise("CUSTODE_CONFIG points at #{path}, not found")

      _unset ->
        default = Custode.Home.resolve_in(&Custode.Home.config_dir/0, "routines.toml")
        if File.exists?(default), do: default
    end
  end

  @doc """
  Parse a TOML document into `{routines, sensors}` in the exs shape.
  Pure -- `load!/0` handles the file and the env.
  """
  def parse!(toml, source \\ "routines.toml") do
    doc =
      case Toml.decode(toml) do
        {:ok, doc} -> doc
        {:error, reason} -> raise "#{source}: #{inspect(reason)}"
      end

    routines =
      for entry <- Map.get(doc, "routines", []), do: convert(entry, @routine_keys, source)

    sensors = for entry <- Map.get(doc, "sensors", []), do: convert(entry, @sensor_keys, source)

    profiles =
      for entry <- Map.get(doc, "profiles", []), into: %{}, do: convert_profile(entry, source)

    {routines, Enum.map(sensors, &resolve_sensor_module(&1, source)), profiles}
  end

  # A [[profiles]] entry: `name` becomes the map key (an atom, the same shape
  # config.exs uses), the rest converts through @profile_keys. A profile with
  # no name is a boot error -- an unkeyable envelope is drift.
  defp convert_profile(entry, source) do
    case Map.fetch(entry, "name") do
      {:ok, name} when is_binary(name) and name != "" ->
        envelope = convert(Map.delete(entry, "name"), @profile_keys, source)
        {String.to_atom(name), envelope}

      _missing ->
        raise "#{source}: a [[profiles]] entry has no name"
    end
  end

  defp convert(entry, allowed, source) do
    Map.new(entry, fn {key, value} ->
      case Map.fetch(allowed, key) do
        {:ok, atom_key} -> {atom_key, convert_value(atom_key, value)}
        :error -> raise "#{source}: unknown key #{inspect(key)} in #{inspect(entry["id"])}"
      end
    end)
  end

  # cron: "manual" is the one magic string; every other cron stays a string
  defp convert_value(:cron, "manual"), do: :manual
  defp convert_value(:cron, cron), do: cron
  # tags are an open vocabulary the operator owns; the file is trusted input
  defp convert_value(:tags, tags), do: Enum.map(tags, &String.to_atom/1)
  # sensors in a profile are atoms (e.g. [:ci]) the same as tags
  defp convert_value(:sensors, sensors), do: Enum.map(sensors, &String.to_atom/1)

  defp convert_value(key, value) when key in @atom_valued and is_binary(value),
    do: String.to_atom(value)

  defp convert_value(_key, value), do: value

  defp resolve_sensor_module(%{module: short} = sensor, source) when is_binary(short) do
    %{sensor | module: Module.safe_concat([Custode.Sensors, short])}
  rescue
    ArgumentError ->
      reraise "#{source}: unknown sensor module #{inspect(short)} (expected a Custode.Sensors.*)",
              __STACKTRACE__
  end

  defp resolve_sensor_module(sensor, _source), do: sensor
end
