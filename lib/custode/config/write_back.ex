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

  defp validate(attrs) do
    id = Map.get(attrs, :id)

    cond do
      not is_binary(id) or id == "" ->
        {:error, :missing_id}

      Enum.any?(Custode.Routine.all(), &(&1.id == id)) ->
        {:error, {:duplicate_id, id}}

      true ->
        # normalize raises on a broken entry; surface that as a value, not a
        # crash, so gate flows can show the reason
        try do
          _normalized = Custode.Routine.normalize_entry(attrs)
          :ok
        rescue
          error -> {:error, {:invalid_entry, Exception.message(error)}}
        end
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
