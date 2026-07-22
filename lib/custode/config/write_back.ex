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
      {:ok, _path, _routines, _sensors} = Loader.load!()
      # a runtime add must also mint the newcomer's identity and MCP config
      # (boot only does this for the roster it saw): without the file, every
      # mcp: true turn dies command_failed until the next restart
      Custode.MCP.write_routine_config!(attrs.id)
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
      path = Loader.target_path()
      ensure_file!(path)
      splice!(path, id, render_routine(merged))
      {:ok, _path, _routines, _sensors} = Loader.load!()
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
    with {:ok, _raw} <- fetch_raw(id) do
      path = Loader.target_path()
      ensure_file!(path)
      splice!(path, id, nil)
      {:ok, _path, _routines, _sensors} = Loader.load!()
      stop_live_agent(id)
      {:ok, path}
    end
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
      :model,
      :effort,
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

      header = """
      # custode roster -- created by Custode.Config.WriteBack from the live
      # in-memory roster (design 001 D4). This file now IS the roster: the
      # config.exs lists are ignored while it exists (D1). Edit freely;
      # changes are live at the scheduler's next minute after a reload.
      """

      body =
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
        {routines, _sensors} = Loader.parse!(File.read!(path), path)
        routines
      else
        Application.fetch_env!(:custode, :routines)
      end

    case Enum.find(entries, &(&1.id == id)) do
      nil -> {:error, {:unknown_id, id}}
      raw -> {:ok, raw}
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
    :model,
    :effort,
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
  defp splice!(path, id, replacement) do
    content = File.read!(path)
    {before_text, after_text} = section_bounds!(content, id, path)

    File.write!(
      path,
      before_text <> ((replacement && String.trim_leading(replacement)) || "") <> after_text
    )
  end

  defp section_bounds!(content, id, path) do
    lines = String.split(content, "\n")

    starts =
      for {line, index} <- Enum.with_index(lines), String.trim(line) == "[[routines]]", do: index

    start =
      Enum.find(starts, fn index ->
        lines
        |> section_lines(index)
        |> Enum.any?(&(String.trim(&1) in [~s(id = "#{id}"), ~s(id = '#{id}')]))
      end) || raise "#{path}: no [[routines]] section with id #{inspect(id)}"

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

  defp stop_live_agent(id) do
    ObanClaude.Agent.stop_agent(id)
  catch
    # not running (or already stopping) is fine: removal is idempotent on the
    # process side, and the roster is already rewritten
    _kind, _reason -> :ok
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
