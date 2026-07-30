defmodule Custode.Definitions do
  @moduledoc """
  Declarative definitions loaded, validated, and frozen before work is
  scheduled (#270, design/008).

  ## The authority boundary is data, not etiquette

  Two owners, and no field answers to both:

      configuration   RoleTemplates, Recipes, provider profiles, static
                      capability defaults, default policies and budgets,
                      bootstrap declarations
      database        Mission identity and lifecycle, live RoleBindings and
                      grants, WorkItems, Attempts, Operations, Gates,
                      Artifacts, leases, history

  `authority/1` answers for any surface, and configuration that reaches for a
  database-owned surface fails to load rather than quietly winning or quietly
  losing. Stating the split as data is what makes "no field has both"
  something a test can check rather than something a reviewer has to notice.

  Nothing here writes back. `routines.toml` remains authoritative for each
  legacy execution field until a named migration moves it once, and a
  runtime-created Mission or RoleBinding never acquires a writable
  configuration twin, because configuration is only ever read.

  ## Precedence

      1. an explicit application-configuration override for that key
      2. the packaged default projected from current config

  First match wins per key. An override may `extends:` another key to inherit
  its values, resolved before the merge, and a cycle in that chain is an
  error rather than a stack overflow.

  ## Errors surface before scheduling, not during

  `verify/0` resolves every reference: prompt assets through
  `Custode.Assets`, verification recipes through
  `Custode.Verification.Recipes`, and provider profiles referenced by
  bootstrap declarations. A definition naming something that does not exist
  is a boot-time error naming both the definition and the missing reference,
  because the alternative is an agent discovering it mid-sweep.

  ## Versions are derived

  A loaded definition carries `sha256:` over its own resolved content, so a
  version cannot drift from what it describes and a live record can record
  exactly which definition it used.
  """

  require Logger

  alias Custode.{Assets, RoleTemplates, Routine}
  alias Custode.Verification.Recipes

  @configuration_owned ~w(
    role_template recipe provider_profile capability_default
    default_policy default_budget bootstrap prompt_asset
  )a

  @database_owned ~w(
    mission role_binding work_item attempt operation_call gate artifact
    workspace_lease work_event observation history
  )a

  @doc "Which owner a surface belongs to."
  @spec authority(atom()) :: :configuration | :database | :unknown
  def authority(surface) when is_atom(surface) do
    cond do
      surface in @configuration_owned -> :configuration
      surface in @database_owned -> :database
      true -> :unknown
    end
  end

  @doc "Every configuration-owned surface."
  @spec configuration_owned() :: [atom()]
  def configuration_owned, do: @configuration_owned

  @doc "Every database-owned surface."
  @spec database_owned() :: [atom()]
  def database_owned, do: @database_owned

  @doc """
  Load every declarative definition, resolved and validated.

  Returns `{:ok, definitions}` or `{:error, problems}` where each problem
  names the definition and what is wrong with it.
  """
  @spec load(keyword()) :: {:ok, map()} | {:error, [map()]}
  def load(options \\ []) do
    overrides = overrides(options)

    with :ok <- no_database_surfaces(overrides),
         {:ok, resolved} <- resolve_overrides(overrides),
         templates = merge_templates(resolved),
         :ok <- validate_references(templates, resolved) do
      {:ok,
       %{
         role_templates: templates,
         provider_profiles: provider_profiles(),
         bootstrap: Map.get(resolved, "bootstrap", %{}),
         version: version(templates, resolved)
       }}
    end
  end

  @doc "Validate without keeping the result."
  @spec verify(keyword()) :: :ok | {:error, [map()]}
  def verify(options \\ []) do
    case load(options) do
      {:ok, _definitions} -> :ok
      {:error, problems} -> {:error, problems}
    end
  end

  @doc """
  Log the loaded definition set, or fail loudly.

  Called at boot so a configuration error is a boot-time complaint naming the
  file to fix, not an agent discovering it three phases into a sweep.
  """
  @spec report() :: :ok
  def report do
    case load() do
      {:ok, definitions} ->
        Logger.info(
          "definitions loaded: #{map_size(definitions.role_templates)} role templates, " <>
            "#{map_size(definitions.provider_profiles)} provider profiles, " <>
            "version #{definitions.version}"
        )

      {:error, problems} ->
        Logger.error("declarative definitions invalid: #{inspect(problems)}")
    end

    :ok
  end

  @doc """
  The read-only compatibility view for one current routine.

  Sourced fields are marked with their origin and carry `writable: false`, so
  a caller can see that the value came from configuration and that writing it
  back is not on offer.
  """
  @spec for_routine(map()) :: map()
  def for_routine(routine) when is_map(routine) do
    template = RoleTemplates.for_routine(routine)

    %{
      key: template.key,
      version: template.version,
      role: template.role,
      source: %{kind: "legacy_routine", id: Map.get(routine, :id), writable: false},
      executor_defaults: template.executor_defaults,
      budget_defaults: template.budget_defaults,
      prompt_assets: template.prompt_assets,
      recipe: template.recipe
    }
  end

  defp overrides(options) do
    options
    |> Keyword.get_lazy(:overrides, fn ->
      Application.get_env(:custode, :definitions, %{})
    end)
    |> Map.new(fn {key, value} -> {to_string(key), Map.new(value)} end)
  rescue
    # a malformed override map is itself a configuration error, reported by
    # the caller rather than raised through boot
    _error -> %{"__invalid__" => %{}}
  end

  # Configuration reaching for a database-owned surface is refused rather than
  # merged. Silently ignoring it would leave two plausible owners for one
  # field, which is the ambiguity this boundary exists to remove.
  defp no_database_surfaces(overrides) do
    violations =
      for {key, declaration} <- overrides,
          surface <- Map.keys(declaration),
          authority(atom(surface)) == :database do
        %{definition: key, problem: "#{surface} is owned by the database, not configuration"}
      end

    if violations == [], do: :ok, else: {:error, violations}
  end

  defp resolve_overrides(overrides) do
    Enum.reduce_while(overrides, {:ok, %{}}, fn {key, _declaration}, {:ok, acc} ->
      case resolve(key, overrides, []) do
        {:ok, resolved} -> {:cont, {:ok, Map.put(acc, key, resolved)}}
        {:error, problem} -> {:halt, {:error, [problem]}}
      end
    end)
  end

  # Keys stay STRINGS. A RoleTemplate key like "role:caretaker" is not an
  # existing atom, so atomizing here would collapse every override onto one
  # sentinel and silently match nothing.

  defp resolve(key, overrides, seen) do
    cond do
      key in seen ->
        {:error,
         %{definition: key, problem: "extends forms a cycle: #{Enum.join(seen ++ [key], " -> ")}"}}

      # name the definition that referenced it AND the thing it wanted; either
      # alone leaves the reader hunting for the other half
      not Map.has_key?(overrides, key) ->
        {:error,
         %{definition: List.last(seen) || key, problem: "extends unknown definition #{key}"}}

      true ->
        declaration = Map.fetch!(overrides, key)
        inherit(declaration, extends(declaration), key, overrides, seen)
    end
  end

  defp extends(declaration),
    do: Map.get(declaration, :extends) || Map.get(declaration, "extends")

  defp inherit(declaration, nil, _key, _overrides, _seen), do: {:ok, declaration}

  defp inherit(declaration, parent, key, overrides, seen) do
    with {:ok, inherited} <- resolve(to_string(parent), overrides, seen ++ [key]) do
      # the child wins every field it names; extends itself never survives
      {:ok, inherited |> Map.merge(declaration) |> Map.drop([:extends, "extends"])}
    end
  end

  defp merge_templates(resolved) do
    Map.new(RoleTemplates.all(), fn {key, template} ->
      case Map.get(resolved, key) do
        nil -> {key, template}
        override -> {key, struct(template, Map.take(override, overridable()))}
      end
    end)
  end

  defp overridable, do: [:executor_defaults, :budget_defaults, :limits, :recipe, :prompt_assets]

  defp validate_references(templates, resolved) do
    problems =
      Enum.flat_map(templates, fn {key, template} ->
        asset_problems(key, template) ++ recipe_problems(key, template)
      end) ++ bootstrap_problems(resolved)

    if problems == [], do: :ok, else: {:error, problems}
  end

  defp asset_problems(key, template) do
    for asset <- List.wrap(template.prompt_assets),
        is_map(asset),
        id = asset["id"] || asset[:id],
        is_binary(id),
        match?({:error, _reason}, Assets.fetch(id)) do
      %{definition: key, problem: "prompt asset #{id} does not resolve"}
    end
  end

  # Only a declared verification recipe is checked. A legacy routine recipe
  # marker names a profile rather than a reviewed command set, and inventing a
  # lookup for it here would make this fail on every current routine.
  defp recipe_problems(key, template) do
    case template.recipe do
      %{"kind" => "verification", "name" => name, "version" => version} ->
        case Recipes.fetch(name, version) do
          {:ok, _recipe} ->
            []

          {:error, _reason} ->
            [%{definition: key, problem: "unknown verification recipe #{name}"}]
        end

      _legacy ->
        []
    end
  end

  defp bootstrap_problems(resolved) do
    profiles = provider_profiles()

    for {key, value} <- Map.get(resolved, "bootstrap", %{}),
        profile = value[:provider_profile] || value["provider_profile"],
        is_binary(profile),
        not Map.has_key?(profiles, atom(profile)) do
      %{definition: "bootstrap.#{key}", problem: "unknown provider profile #{profile}"}
    end
  end

  defp provider_profiles do
    Routine.profiles()
  rescue
    _error -> %{}
  end

  defp version(templates, resolved) do
    digest =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({canonical(templates), canonical(resolved)}))
      |> Base.encode16(case: :lower)

    "sha256:" <> digest
  end

  defp canonical(map) when is_map(map) and not is_struct(map) do
    map |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end) |> Enum.sort()
  end

  defp canonical(%_struct{} = value), do: value |> Map.from_struct() |> canonical()
  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value

  defp atom(value) when is_atom(value), do: value

  defp atom(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> :"$unknown"
  end
end
