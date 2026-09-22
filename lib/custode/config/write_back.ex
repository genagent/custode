defmodule Custode.Config.WriteBack do
  @moduledoc """
  Config write-back (#75 / design 001 slice 2): a new routine becomes a TOML
  section appended to the routines file, and the running roster picks it up
  in the same operation -- file + env together, one gated write, no drift
  between what git shows and what the fleet runs (D4).

  The flow every surface funnels through (`add_routine/1`):

    1. validate: the entry must normalize (the same `Routine.normalize/1`
       every roster source flows through) and its id must be new
    2. render: a `[[routines]]` TOML section, exactly what an operator
       would have typed
    3. append: to the resolved routines file. When NO file exists yet, the
       first write-back CREATES it by rendering the entire current in-memory
       roster first -- migration off the exs lists is a side effect of first
       use, not a project.
    4. reload: `Loader.load!/0`, so the new routine is beatable immediately
       and (with #142's scheduler reading the roster each minute) scheduled
       at the next matching minute. No restart.

  What this module does NOT do: decide authority. Callers gate. An agent
  proposing an add goes through request_permission with the RENDERED section
  in the gate description (slice 3 wires that tool); a human driving the
  dashboard form or CLI is their own authority. Policy hooks (D5) also live
  with the callers.

  `render_routine/1` is public and pure precisely so slice 3's gate card can
  show the operator the literal text that approval will append.
  """

  alias Custode.Config.Loader
  alias Custode.Routine.Effort

  @doc """
  Append `attrs` (an atom-keyed routine entry in the exs/loader shape) to the
  routines file and reload the running roster. Returns `{:ok, path}`,
  `{:error, reason}` on a duplicate id or an entry that fails normalization.
  """
  def add_routine(attrs) when is_map(attrs) do
    with :ok <- validate(attrs) do
      path = Loader.target_path()
      ensure_file!(path)
      File.write!(path, render_routine(attrs), [:append])
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      # a runtime add must also mint the newcomer's identity and MCP config
      # (boot only does this for the roster it saw): without the file, every
      # mcp: true turn dies command_failed until the next restart
      Custode.MCP.write_routine_config!(attrs.id)
      # ...and its workspace (#496): the notebook re-renders journal.md into it
      # on every write, and boot only created workspaces for the roster it saw
      attrs.id |> Custode.Routine.get() |> Custode.Routine.ensure_workspace!()
      # ...and its repo server (#221): served?/1 is a Registry lookup, and
      # boot only starts servers for the roster it saw
      if is_binary(attrs[:repo]), do: Custode.Repository.ensure_served(attrs.repo, attrs.id)
      {:ok, path}
    end
  end

  @doc """
  Edit an existing routine (#174 slice 1). `changes` is an atom-keyed map of
  fields to swap on the RAW entry -- never the normalized one, so a five-line
  assignment stays five lines and its profile keeps supplying the defaults.
  A key set to `nil` DROPS that override (back to the profile's value). The
  id itself is immutable; remove + add is the rename path.

  The edit rewrites only the entry's own `[[routines]]` section in the file
  (a textual splice), so hand comments on OTHER entries survive byte-for-byte;
  comments inside the edited section are lost (documented v1 trade). With no
  roster file yet, the first edit CREATES one from the live roster -- the
  design 001 mode switch; surfaces must present that deliberately.
  """
  def update_routine(id, changes) when is_binary(id) and is_map(changes) do
    with :ok <- validate_changes(changes),
         {:ok, raw} <- fetch_raw(id),
         merged = merge_changes(raw, changes),
         :ok <- validate_entry(merged) do
      old_provider = Custode.Routine.get(id).provider
      path = Loader.target_path()
      ensure_file!(path)
      splice!(path, id, render_routine(merged))
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      new_provider = Custode.Routine.get(id).provider

      if old_provider != new_provider do
        stop_live_agent(id, old_provider)
        Custode.MCP.write_routine_config!(id)
      end

      # a repo change serves the new one and retires the old if orphaned (#221)
      if is_binary(merged[:repo]), do: Custode.Repository.ensure_served(merged.repo, id)
      old_repo = Map.get(raw, :repo)

      if is_binary(old_repo) and old_repo != merged[:repo],
        do: Custode.Repository.stop_serving(old_repo)

      {:ok, path}
    end
  end

  @doc """
  The RAW roster entry for an id -- what the file (or exs list) literally
  says, before any profile default applies. The edit form prefills from
  this so an edit can never bake defaults into the file (#174 slice 2).
  """
  def raw_entry(id) when is_binary(id), do: fetch_raw(id)

  @doc """
  Render the before/after TOML sections an edit would produce, without
  writing anything (#174 slice 3): a caretaker puts BOTH in its
  request_permission action so the human approves the literal change.
  Validates exactly like `update_routine/2`.
  """
  def preview_update(id, changes) when is_binary(id) and is_map(changes) do
    with :ok <- validate_changes(changes),
         {:ok, raw} <- fetch_raw(id),
         merged = merge_changes(raw, changes),
         :ok <- validate_entry(merged) do
      {:ok, %{before: render_routine(raw), after: render_routine(merged)}}
    end
  end

  @doc """
  Remove a routine from the roster (#174 slice 1): splice its section out of
  the file, reload, and stop the live agent if one is running. The notebook
  and workspace are deliberately kept -- records outlive routines (design
  002). Sensors that notify the departed id are left in place for the
  operator to prune.
  """
  def remove_routine(id) when is_binary(id) do
    with {:ok, raw} <- fetch_raw(id) do
      provider = Custode.Routine.get(id).provider
      path = Loader.target_path()
      ensure_file!(path)
      raw_repo = Map.get(raw, :repo)
      splice!(path, id, nil)
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      stop_live_agent(id, provider)
      if is_binary(raw_repo), do: Custode.Repository.stop_serving(raw_repo)
      {:ok, path}
    end
  end

  # ------------------------------------------------------------------
  # Profiles (#236): the same file+reload-in-one-op shape as routines, held
  # tighter because a profile carries the dangerous grants (approved_args
  # bypass_permissions, extra_allowed_tools Bash, role). Callers gate; the
  # MCP surface is caretaker-only and always request_permission with the
  # rendered TOML in the action so the human approves the literal grants.
  # ------------------------------------------------------------------

  @doc """
  Add a profile (#236): render a `[[profiles]]` section, append it to the
  roster file, and reload so routines can inherit it immediately. `name` is
  the profile key (a string; becomes an atom), `envelope` an atom-keyed map
  of the inherited fields. Refuses a duplicate name or a malformed envelope.
  """
  def add_profile(name, envelope) when is_binary(name) and is_map(envelope) do
    with :ok <- validate_profile_name(name, :new),
         :ok <- validate_profile_envelope(envelope) do
      path = Loader.target_path()
      ensure_file!(path)
      File.write!(path, render_profile(name, envelope), [:append])
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      {:ok, path}
    end
  end

  @doc """
  Edit a profile (#236): merge `changes` onto the existing envelope (a key
  set to `nil` DROPS it), rewrite only that profile's section, and reload.
  Every routine wearing the profile inherits the change at the next run.
  """
  def update_profile(name, changes) when is_binary(name) and is_map(changes) do
    with :ok <- validate_profile_name(name, :existing),
         {:ok, envelope} <- fetch_profile(name),
         merged = merge_changes(envelope, changes),
         :ok <- validate_profile_envelope(merged) do
      old_providers = profile_wearer_providers(name)
      path = Loader.target_path()
      ensure_file!(path)
      splice_profile!(path, name, render_profile(name, merged))
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      reconcile_profile_provider_changes(old_providers)
      {:ok, path}
    end
  end

  @doc """
  Remove a profile (#236): splice its section out and reload. Refused when a
  routine still wears it -- pulling the envelope out from under a live
  routine would strip its grants mid-flight; reassign those routines first.
  """
  def remove_profile(name) when is_binary(name) do
    with :ok <- validate_profile_name(name, :existing),
         :ok <- no_routine_wears(name) do
      path = Loader.target_path()
      ensure_file!(path)
      splice_profile!(path, name, nil)
      {:ok, _path, _routines, _sensors, _profiles} = Loader.load!()
      {:ok, path}
    end
  end

  @doc """
  Render the before/after TOML an edit would produce, plus the dangerous
  grants each side carries (#236), without writing: a caretaker puts this in
  its request_permission action so the human sees the literal change AND the
  privilege surface it moves.
  """
  def preview_profile(name, changes) when is_binary(name) and is_map(changes) do
    with :ok <- validate_profile_name(name, :existing),
         {:ok, envelope} <- fetch_profile(name),
         merged = merge_changes(envelope, changes),
         :ok <- validate_profile_envelope(merged) do
      {:ok,
       %{
         before: render_profile(name, envelope),
         after: render_profile(name, merged),
         grants: dangerous_grants(merged)
       }}
    end
  end

  @doc """
  Render a new profile's TOML plus its dangerous grants, without writing
  (#236): the define-flow's gate card. Validates like `add_profile/2`.
  """
  def preview_new_profile(name, envelope) when is_binary(name) and is_map(envelope) do
    with :ok <- validate_profile_name(name, :new),
         :ok <- validate_profile_envelope(envelope) do
      {:ok, %{toml: render_profile(name, envelope), grants: dangerous_grants(envelope)}}
    end
  end

  @doc """
  The dangerous grants an envelope carries (#236), for the gate card: a
  bypass_permissions approved_arg, any extra_allowed_tools, and the role.
  Surfacing these is the escalation flag -- the human sees exactly what a
  profile hands its wearers before approving it.
  """
  def dangerous_grants(envelope) when is_map(envelope) do
    []
    |> flag_bypass(Map.get(envelope, :approved_args))
    |> flag_tools(Map.get(envelope, :extra_allowed_tools))
    |> flag_role(Map.get(envelope, :role))
    |> Enum.reverse()
  end

  defp flag_bypass(flags, %{} = args) do
    # approved_args are string-keyed (they mirror the wrapper's arg names)
    case args["permission_mode"] || args[:permission_mode] do
      "bypass_permissions" -> ["approved_args grants bypass_permissions" | flags]
      _other -> flags
    end
  end

  defp flag_bypass(flags, _none), do: flags

  defp flag_tools(flags, [_ | _] = tools),
    do: ["extra_allowed_tools: #{Enum.join(tools, ", ")}" | flags]

  defp flag_tools(flags, _none), do: flags

  defp flag_role(flags, role) when is_atom(role) and not is_nil(role),
    do: ["role: #{role}" | flags]

  defp flag_role(flags, _none), do: flags

  @doc """
  Render one profile as a `[[profiles]]` TOML section -- the exact text
  `add_profile/2` appends, for gate cards and previews.
  """
  def render_profile(name, envelope) do
    keys = [
      :cron,
      :prompt,
      :role,
      :provider,
      :model,
      :effort,
      :agent,
      :workspace,
      :working_dir,
      :mcp,
      :hermetic,
      :max_budget_usd,
      :daily_budget_usd,
      :daily_budget_tokens,
      :timeout_ms,
      :max_turns,
      :tags,
      :sensors,
      :system_prompt,
      :system_prompt_file,
      :extra_allowed_tools
    ]

    lines =
      for key <- keys, Map.has_key?(envelope, key) do
        "#{key} = #{toml_value(Map.fetch!(envelope, key))}"
      end

    approved =
      case Map.get(envelope, :approved_args) do
        %{} = args when map_size(args) > 0 ->
          [
            "[profiles.approved_args]"
            | for({k, v} <- Enum.sort(args), do: "#{k} = #{toml_value(v)}")
          ]

        _none ->
          []
      end

    Enum.join(["\n[[profiles]]", ~s(name = #{inspect(name)})] ++ lines ++ approved, "\n") <> "\n"
  end

  @doc """
  Render one routine entry as a `[[routines]]` TOML section -- the exact
  text `add_routine/1` appends, for gate cards and previews.
  """
  def render_routine(attrs) do
    keys = [
      :id,
      :profile,
      :cron,
      :repo,
      :workspace,
      :working_dir,
      :tags,
      :prompt,
      :role,
      :provider,
      :model,
      :effort,
      :agent,
      :mcp,
      :max_budget_usd,
      :daily_budget_usd,
      :daily_budget_tokens,
      :timeout_ms,
      :max_turns,
      :hermetic,
      :system_prompt,
      :system_prompt_file,
      :extra_allowed_tools
    ]

    lines =
      for key <- keys, Map.has_key?(attrs, key) do
        "#{key} = #{toml_value(Map.fetch!(attrs, key))}"
      end

    approved =
      case Map.get(attrs, :approved_args) do
        %{} = args when map_size(args) > 0 ->
          [
            "[routines.approved_args]"
            | for({k, v} <- Enum.sort(args), do: "#{k} = #{toml_value(v)}")
          ]

        _none ->
          []
      end

    Enum.join(["\n[[routines]]"] ++ lines ++ approved, "\n") <> "\n"
  end

  # First write-back with no file: render the ENTIRE current roster so the
  # file is born complete and wins outright from its first moment (D1 has no
  # partial-file mode -- a file that existed but lacked the exs routines
  # would silently drop them).
  defp ensure_file!(path) do
    unless File.exists?(path) do
      routines = Application.fetch_env!(:custode, :routines)
      sensors = Application.get_env(:custode, :sensors, [])
      profiles = Application.get_env(:custode, :profiles, %{})

      header = """
      # custode roster -- created by Custode.Config.WriteBack from the live
      # in-memory roster (design 001 D4). This file now IS the roster: the
      # config.exs lists are ignored while it exists (D1). Edit freely;
      # changes are live at the scheduler's next minute after a reload.
      """

      # Profiles ride the same file (#236). They must be dumped here too:
      # once this file exists the loader takes profiles from it (D1), so a
      # first write-back that omitted them would silently drop every
      # config.exs profile the routines inherit from.
      body =
        Enum.map_join(profiles, "", fn {name, envelope} ->
          render_profile(Atom.to_string(name), envelope)
        end) <>
          Enum.map_join(routines, "", &render_routine/1) <>
          Enum.map_join(sensors, "", &render_sensor/1)

      File.write!(path, header <> body)
    end
  end

  defp render_sensor(sensor) do
    lines =
      for key <- [:id, :cron, :notify], Map.has_key?(sensor, key) do
        "#{key} = #{toml_value(Map.fetch!(sensor, key))}"
      end

    module_line = "module = #{toml_value(short_module(sensor.module))}"

    args =
      case Map.get(sensor, :args) do
        %{} = map when map_size(map) > 0 ->
          ["[sensors.args]" | for({k, v} <- Enum.sort(map), do: "#{k} = #{toml_value(v)}")]

        _none ->
          []
      end

    Enum.join(["\n[[sensors]]"] ++ lines ++ [module_line] ++ args, "\n") <> "\n"
  end

  defp short_module(module) when is_atom(module) do
    module |> Module.split() |> List.last()
  end

  # The RAW entry for an id. The file is the truth when it exists (an
  # operator may have hand-edited it since the last reload), the env
  # otherwise -- same precedence the loader lives by.
  defp fetch_raw(id) do
    # read via target_path, not Loader.load/0: a set-but-absent
    # CUSTODE_CONFIG raises there, but here it just means exs mode
    path = Loader.target_path()

    entries =
      if File.exists?(path) do
        {routines, _sensors, _profiles} = Loader.parse!(File.read!(path), path)
        routines
      else
        Application.fetch_env!(:custode, :routines)
      end

    case Enum.find(entries, &(&1.id == id)) do
      nil -> {:error, {:unknown_id, id}}
      raw -> {:ok, raw}
    end
  end

  # The current profile map: the file when it exists (an operator may have
  # hand-edited it), the env otherwise -- the loader's precedence (#236).
  defp all_profiles do
    path = Loader.target_path()

    if File.exists?(path) do
      {_routines, _sensors, profiles} = Loader.parse!(File.read!(path), path)
      profiles
    else
      Application.get_env(:custode, :profiles, %{})
    end
  end

  defp fetch_profile(name) do
    case Map.fetch(all_profiles(), String.to_atom(name)) do
      {:ok, envelope} -> {:ok, envelope}
      :error -> {:error, {:unknown_profile, name}}
    end
  end

  defp validate_profile_name(name, expect) do
    exists? = Map.has_key?(all_profiles(), safe_atom(name))

    cond do
      not is_binary(name) or name == "" -> {:error, :missing_name}
      expect == :new and exists? -> {:error, {:duplicate_profile, name}}
      expect == :existing and not exists? -> {:error, {:unknown_profile, name}}
      true -> :ok
    end
  end

  # An atom that does not exist cannot be a live profile name; treat it as
  # absent rather than minting an atom from untrusted input.
  defp safe_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> :__custode_no_such_profile__
  end

  @profile_keys [
    :cron,
    :prompt,
    :role,
    :provider,
    :model,
    :effort,
    :agent,
    :workspace,
    :working_dir,
    :mcp,
    :hermetic,
    :max_budget_usd,
    :daily_budget_usd,
    :daily_budget_tokens,
    :timeout_ms,
    :max_turns,
    :tags,
    :sensors,
    :system_prompt,
    :system_prompt_file,
    :extra_allowed_tools,
    :approved_args
  ]

  # A profile envelope must be non-empty and carry only known keys. Unlike a
  # routine it is not normalized here (it has no id and is a template, not an
  # instance); the routines wearing it validate at their own normalize.
  defp validate_profile_envelope(envelope) do
    cond do
      map_size(envelope) == 0 -> {:error, :empty_profile}
      (unknown = Map.keys(envelope) -- @profile_keys) != [] -> {:error, {:unknown_keys, unknown}}
      true -> validate_profile_effort(envelope)
    end
  end

  defp validate_profile_effort(envelope) do
    case Effort.normalize(Map.get(envelope, :effort)) do
      {:ok, _effort} -> :ok
      {:error, message} -> {:error, {:invalid_profile, message}}
    end
  end

  # A profile in use cannot be removed: its wearers would lose their whole
  # envelope (grants, budgets, role) at the next reload (#236). Checked on
  # RAW entries -- Routine.all/0 has already folded the profile away.
  defp no_routine_wears(name) do
    atom = safe_atom(name)

    case Enum.filter(raw_routines(), &(&1[:profile] == atom)) do
      [] -> :ok
      wearers -> {:error, {:profile_in_use, Enum.map(wearers, & &1.id)}}
    end
  end

  defp raw_routines do
    path = Loader.target_path()

    if File.exists?(path) do
      {routines, _sensors, _profiles} = Loader.parse!(File.read!(path), path)
      routines
    else
      Application.fetch_env!(:custode, :routines)
    end
  end

  @editable_keys [
    :cron,
    :profile,
    :workspace,
    :working_dir,
    :repo,
    :tags,
    :prompt,
    :role,
    :provider,
    :model,
    :effort,
    :agent,
    :mcp,
    :hermetic,
    :max_budget_usd,
    :daily_budget_usd,
    :daily_budget_tokens,
    :timeout_ms,
    :max_turns,
    :system_prompt,
    :system_prompt_file,
    :extra_allowed_tools,
    :approved_args
  ]

  defp validate_changes(changes) do
    cond do
      Map.has_key?(changes, :id) ->
        {:error, :id_is_immutable}

      map_size(changes) == 0 ->
        {:error, :empty_changes}

      (unknown = Map.keys(changes) -- @editable_keys) != [] ->
        {:error, {:unknown_keys, unknown}}

      true ->
        :ok
    end
  end

  # nil drops the override so the profile's value serves again
  defp merge_changes(raw, changes) do
    raw
    |> Map.merge(changes)
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  # Replace (or, with nil, delete) the one [[routines]] section whose id
  # matches. Everything outside that section is preserved byte-for-byte.
  defp splice!(path, id, replacement),
    do: splice_section!(path, "[[routines]]", "id", id, replacement)

  # The same textual splice for a [[profiles]] section keyed by name (#236).
  defp splice_profile!(path, name, replacement),
    do: splice_section!(path, "[[profiles]]", "name", name, replacement)

  defp splice_section!(path, header, key, value, replacement) do
    content = File.read!(path)
    {before_text, after_text} = section_bounds!(content, header, key, value, path)

    File.write!(
      path,
      before_text <> ((replacement && String.trim_leading(replacement)) || "") <> after_text
    )
  end

  defp section_bounds!(content, header, key, value, path) do
    lines = String.split(content, "\n")

    starts =
      for {line, index} <- Enum.with_index(lines), String.trim(line) == header, do: index

    match_lines = [~s(#{key} = "#{value}"), ~s(#{key} = '#{value}')]

    start =
      Enum.find(starts, fn index ->
        lines
        |> section_lines(index)
        |> Enum.any?(&(String.trim(&1) in match_lines))
      end) || raise "#{path}: no #{header} section with #{key} #{inspect(value)}"

    finish = next_section_index(lines, start)
    before_text = lines |> Enum.take(start) |> join_lines(:before)
    after_text = lines |> Enum.drop(finish) |> join_lines(:after)
    {before_text, after_text}
  end

  defp section_lines(lines, start) do
    lines
    |> Enum.drop(start + 1)
    |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "[[")))
  end

  defp next_section_index(lines, start) do
    count =
      lines
      |> Enum.drop(start + 1)
      |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "[[")))
      |> length()

    start + 1 + count
  end

  defp join_lines([], _position), do: ""
  defp join_lines(lines, :before), do: Enum.join(lines, "\n") <> "\n"
  defp join_lines(lines, :after), do: "\n" <> Enum.join(lines, "\n")

  defp stop_live_agent(id, provider) do
    Custode.Agents.stop_agent(id, provider)
  catch
    # not running (or already stopping) is fine: removal is idempotent on the
    # process side, and the roster is already rewritten
    _kind, _reason -> :ok
  end

  defp profile_wearer_providers(name) do
    for routine <- Custode.Routine.all(),
        routine.profile == String.to_existing_atom(name),
        into: %{} do
      {routine.id, routine.provider}
    end
  end

  defp reconcile_profile_provider_changes(old_providers) do
    Enum.each(old_providers, fn {id, old_provider} ->
      case Custode.Routine.get(id) do
        %{provider: new_provider} when new_provider != old_provider ->
          stop_live_agent(id, old_provider)
          Custode.MCP.write_routine_config!(id)

        _unchanged_or_removed ->
          :ok
      end
    end)
  end

  # normalize raises on a broken entry; surface that as a value, not a
  # crash, so gate flows can show the reason
  defp validate_entry(attrs) do
    _normalized = Custode.Routine.normalize_entry(attrs)
    :ok
  rescue
    error -> {:error, {:invalid_entry, Exception.message(error)}}
  end

  defp validate(attrs) do
    id = Map.get(attrs, :id)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :missing_id}

      Enum.any?(Custode.Routine.all(), &(&1.id == id)) ->
        {:error, {:duplicate_id, id}}

      true ->
        validate_entry(attrs)
    end
  end

  # TOML value rendering for the small vocabulary the roster uses.
  defp toml_value(value) when is_binary(value), do: inspect(value)
  defp toml_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp toml_value(:manual), do: ~s("manual")
  defp toml_value(value) when is_atom(value), do: inspect(Atom.to_string(value))

  defp toml_value(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ", ", &toml_value/1) <> "]"
end
