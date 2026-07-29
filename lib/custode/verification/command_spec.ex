defmodule Custode.Verification.CommandSpec do
  @moduledoc """
  One reviewed, shell-free command definition for deterministic verification.

  The specification is a value embedded in a ContextBundle. Its digest covers
  every execution-sensitive field so a changed command, environment, timeout,
  or output policy cannot reuse older evidence.
  """

  @categories ~w(format test static_analysis repository)
  @risks ~w(read internal_write external_write destructive)
  @shells ~w(sh bash dash fish ksh zsh)
  @forbidden_environment ~w(BASH_ENV ENV LD_PRELOAD DYLD_INSERT_LIBRARIES)
  @max_timeout_ms 3_600_000
  @max_output_limit_bytes 10_000_000
  @max_tail_bytes 64_000

  @enforce_keys [
    :name,
    :category,
    :argv,
    :working_directory,
    :environment_allowlist,
    :environment,
    :timeout_ms,
    :output_limit_bytes,
    :tail_bytes,
    :expected_exit_codes,
    :risk,
    :shell,
    :reviewed,
    :digest
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    definition = %{
      name: field(attrs, :name),
      category: field(attrs, :category),
      argv: field(attrs, :argv),
      working_directory: field(attrs, :working_directory, "."),
      environment_allowlist: field(attrs, :environment_allowlist, []),
      environment: field(attrs, :environment, %{}),
      timeout_ms: field(attrs, :timeout_ms),
      output_limit_bytes: field(attrs, :output_limit_bytes),
      tail_bytes: field(attrs, :tail_bytes),
      expected_exit_codes: field(attrs, :expected_exit_codes, [0]),
      risk: field(attrs, :risk, "read"),
      shell: field(attrs, :shell, false),
      reviewed: field(attrs, :reviewed, false)
    }

    with :ok <- validate_command(definition),
         :ok <- validate_limits(definition),
         :ok <- validate_policy(definition) do
      digest = digest(definition)
      observed_digest = field(attrs, :digest)

      if is_nil(observed_digest) or observed_digest == digest do
        {:ok, struct!(__MODULE__, Map.put(definition, :digest, digest))}
      else
        {:error, {:command_spec_digest_mismatch, definition.name}}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_command_spec}

  @spec render(t()) :: map()
  def render(%__MODULE__{} = spec), do: spec |> Map.from_struct() |> normalize()

  defp validate_command(definition) do
    with :ok <- validate_name(definition.name),
         :ok <- inclusion(:category, definition.category, @categories),
         :ok <- validate_argv(definition.argv),
         :ok <- validate_working_directory(definition.working_directory) do
      validate_environment(definition)
    end
  end

  defp validate_limits(definition) do
    with :ok <- positive(:timeout_ms, definition.timeout_ms),
         :ok <- positive(:output_limit_bytes, definition.output_limit_bytes),
         :ok <- positive(:tail_bytes, definition.tail_bytes),
         :ok <- at_most(:timeout_ms, definition.timeout_ms, @max_timeout_ms),
         :ok <-
           at_most(
             :output_limit_bytes,
             definition.output_limit_bytes,
             @max_output_limit_bytes
           ),
         :ok <- at_most(:tail_bytes, definition.tail_bytes, @max_tail_bytes),
         :ok <- tail_within_limit(definition) do
      validate_exit_codes(definition.expected_exit_codes)
    end
  end

  defp validate_policy(definition) do
    with :ok <- inclusion(:risk, definition.risk, @risks),
         :ok <- validate_boolean(:shell, definition.shell),
         :ok <- validate_boolean(:reviewed, definition.reviewed),
         :ok <- reviewed(definition) do
      shell_policy(definition)
    end
  end

  defp validate_name(name) when is_binary(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, name),
      do: :ok,
      else: {:error, {:invalid_command_name, name}}
  end

  defp validate_name(name), do: {:error, {:invalid_command_name, name}}

  defp validate_argv([executable | arguments])
       when is_binary(executable) and executable != "" and is_list(arguments) do
    if Enum.all?([executable | arguments], &valid_argument?/1),
      do: :ok,
      else: {:error, :invalid_command_argv}
  end

  defp validate_argv(_argv), do: {:error, :invalid_command_argv}

  defp valid_argument?(argument),
    do: is_binary(argument) and not String.contains?(argument, <<0>>)

  defp validate_working_directory(path) when is_binary(path) and path != "" do
    cond do
      Path.type(path) != :relative -> {:error, :absolute_working_directory_refused}
      ".." in Path.split(path) -> {:error, :working_directory_escape_refused}
      String.contains?(path, <<0>>) -> {:error, :invalid_working_directory}
      true -> :ok
    end
  end

  defp validate_working_directory(_path), do: {:error, :invalid_working_directory}

  defp validate_environment(definition) do
    allowlist = definition.environment_allowlist
    environment = definition.environment

    cond do
      not is_list(allowlist) or not Enum.all?(allowlist, &valid_environment_key?/1) ->
        {:error, :invalid_environment_allowlist}

      length(Enum.uniq(allowlist)) != length(allowlist) ->
        {:error, :duplicate_environment_allowlist}

      not is_map(environment) ->
        {:error, :invalid_environment}

      not Enum.all?(environment, &valid_environment_pair?/1) ->
        {:error, :invalid_environment}

      Enum.any?(Map.keys(environment), &(to_string(&1) not in allowlist)) ->
        {:error, :environment_injection_refused}

      Enum.any?(allowlist, &forbidden_environment?/1) ->
        {:error, :environment_injection_refused}

      true ->
        :ok
    end
  end

  defp valid_environment_pair?({key, value}),
    do: valid_environment_key?(to_string(key)) and valid_argument?(value)

  defp valid_environment_key?(key) when is_binary(key),
    do: Regex.match?(~r/^[A-Z_][A-Z0-9_]*$/, key)

  defp valid_environment_key?(_key), do: false

  defp forbidden_environment?(key) do
    key in @forbidden_environment or String.starts_with?(key, ["LD_", "DYLD_"])
  end

  defp positive(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive(field, _value), do: {:error, {:invalid_positive_integer, field}}

  defp at_most(_field, value, maximum) when value <= maximum, do: :ok
  defp at_most(field, _value, maximum), do: {:error, {:limit_exceeded, field, maximum}}

  defp tail_within_limit(%{tail_bytes: tail, output_limit_bytes: limit}) when tail <= limit,
    do: :ok

  defp tail_within_limit(_definition), do: {:error, :tail_exceeds_output_limit}

  defp validate_exit_codes(codes) when is_list(codes) and codes != [] do
    if Enum.all?(codes, &(is_integer(&1) and &1 >= 0 and &1 <= 255)),
      do: :ok,
      else: {:error, :invalid_expected_exit_codes}
  end

  defp validate_exit_codes(_codes), do: {:error, :invalid_expected_exit_codes}

  defp inclusion(field, value, allowed) do
    if value in allowed, do: :ok, else: {:error, {:invalid_value, field, value}}
  end

  defp validate_boolean(_field, value) when value in [true, false], do: :ok
  defp validate_boolean(field, _value), do: {:error, {:invalid_boolean, field}}

  defp reviewed(%{reviewed: true}), do: :ok
  defp reviewed(_definition), do: {:error, :unreviewed_command_refused}

  defp shell_policy(%{argv: [executable | arguments], shell: false}) do
    if Path.basename(executable) in @shells and "-c" in arguments,
      do: {:error, :shell_interpretation_requires_explicit_risk},
      else: :ok
  end

  defp shell_policy(%{shell: true, risk: "read"}),
    do: {:error, :shell_interpretation_requires_higher_risk}

  defp shell_policy(%{shell: true}), do: :ok

  defp digest(definition) do
    definition
    |> normalize()
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, nested} -> {to_string(key), canonical(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp normalize(map) when is_map(map) do
    Map.new(map, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(list) when is_list(list), do: Enum.map(list, &normalize/1)
  defp normalize(value), do: value

  defp field(map, key, default \\ nil) do
    case Map.fetch(map, key) do
      {:ok, nested} -> nested
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end
end
