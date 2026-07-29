defmodule Custode.Verification.Recipe do
  @moduledoc "A reviewed set of named deterministic verification commands."

  alias Custode.Verification.CommandSpec

  @required_categories ~w(format test static_analysis repository)
  @max_commands 32

  @enforce_keys [:name, :version, :commands, :digest]
  defstruct @enforce_keys

  @type t :: %__MODULE__{}

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)
    name = value(attrs, :name)
    version = value(attrs, :version)

    with :ok <- validate_identity(name, version),
         {:ok, commands} <- command_specs(value(attrs, :commands)),
         :ok <- unique_names(commands),
         :ok <- required_categories(commands) do
      definition = %{name: name, version: version, commands: commands}
      digest = digest(definition)
      observed_digest = value(attrs, :digest)

      if is_nil(observed_digest) or observed_digest == digest do
        {:ok, %__MODULE__{name: name, version: version, commands: commands, digest: digest}}
      else
        {:error, {:verification_recipe_digest_mismatch, name}}
      end
    end
  end

  def new(_attrs), do: {:error, :invalid_verification_recipe}

  @spec render(t()) :: map()
  def render(%__MODULE__{} = recipe) do
    %{
      "name" => recipe.name,
      "version" => recipe.version,
      "digest" => recipe.digest,
      "commands" => Enum.map(recipe.commands, &CommandSpec.render/1)
    }
  end

  defp validate_identity(name, version)
       when is_binary(name) and name != "" and is_binary(version) and version != "",
       do: :ok

  defp validate_identity(_name, _version), do: {:error, :invalid_verification_recipe_identity}

  defp command_specs(commands)
       when is_list(commands) and commands != [] and length(commands) <= @max_commands do
    Enum.reduce_while(commands, {:ok, []}, fn command, {:ok, parsed} ->
      case CommandSpec.new(command) do
        {:ok, spec} -> {:cont, {:ok, [spec | parsed]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _reason} = error -> error
    end
  end

  defp command_specs(commands) when is_list(commands) and length(commands) > @max_commands,
    do: {:error, {:verification_command_limit, @max_commands}}

  defp command_specs(_commands), do: {:error, :verification_commands_required}

  defp unique_names(commands) do
    names = Enum.map(commands, & &1.name)
    if Enum.uniq(names) == names, do: :ok, else: {:error, :duplicate_verification_command}
  end

  defp required_categories(commands) do
    categories = Enum.map(commands, & &1.category)
    missing = @required_categories -- categories
    if missing == [], do: :ok, else: {:error, {:missing_verification_categories, missing}}
  end

  defp digest(definition) do
    definition
    |> Map.update!(:commands, &Enum.map(&1, fn command -> CommandSpec.render(command) end))
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

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
