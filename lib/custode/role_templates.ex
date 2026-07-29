defmodule Custode.RoleTemplates do
  @moduledoc """
  Deterministic RoleTemplate definitions projected from current config.

  `Custode.Roles` remains the compatibility authority for role hierarchy and
  grants. Routine profiles remain the authority for reusable executor
  defaults. This module gives both inputs one versioned, transport-neutral
  shape without copying them into the database.
  """

  alias Custode.{Roles, RoleTemplate, Routine}

  @executor_fields ~w(model effort timeout_ms max_turns hermetic agent mcp)a
  @budget_fields ~w(max_budget_usd daily_budget_usd daily_budget_tokens)a
  @limit_fields ~w(approved_args extra_allowed_tools)a

  @spec all() :: %{String.t() => RoleTemplate.t()}
  def all do
    role_templates =
      Map.new(Roles.all(), fn {role, _metadata} -> template_pair(:role, role, %{}) end)

    profile_templates =
      Map.new(Routine.profiles(), fn {profile, declaration} ->
        role = Map.get(declaration, :role, :assistant)
        template_pair(:profile, profile, Map.put(declaration, :role, role))
      end)

    Map.merge(role_templates, profile_templates)
  end

  @spec list() :: [RoleTemplate.t()]
  def list, do: all() |> Map.values() |> Enum.sort_by(& &1.key)

  @spec fetch(String.t()) :: {:ok, RoleTemplate.t()} | :error
  def fetch(key), do: Map.fetch(all(), key)

  @spec fetch!(String.t()) :: RoleTemplate.t()
  def fetch!(key), do: Map.fetch!(all(), key)

  @spec for_routine(map()) :: RoleTemplate.t()
  def for_routine(routine) do
    profile = value(routine, :profile)
    role = value(routine, :role)

    cond do
      not is_nil(profile) and match?({:ok, _template}, fetch("profile:#{profile}")) ->
        fetch!("profile:#{profile}")

      Roles.known?(role) ->
        fetch!("role:#{role}")

      true ->
        fetch!("role:assistant")
    end
  end

  @spec render(RoleTemplate.t()) :: map()
  def render(%RoleTemplate{} = template), do: Map.from_struct(template)

  @spec effective_defaults(RoleTemplate.t()) :: map()
  def effective_defaults(%RoleTemplate{} = template) do
    template.executor_defaults
    |> Map.merge(template.budget_defaults)
    |> Map.merge(template.limits)
  end

  defp template_pair(kind, name, declaration) do
    key = "#{kind}:#{name}"
    role = Map.get(declaration, :role, name) |> effective_role()
    metadata = Roles.get(role)
    defaults = defaults(declaration)

    definition = %{
      key: key,
      role: to_string(role),
      responsibility: metadata.summary,
      intent: %{
        "watches" => to_string(metadata.watches),
        "writes" => Enum.map(metadata.writes, &to_string/1),
        "cadence" => to_string(metadata.cadence),
        "singleton" => Map.get(metadata, :singleton, false)
      },
      operation_grants: [role |> Roles.grants() |> to_string()],
      transport_allowlists: %{"mcp" => Routine.mcp_tools(role)},
      recipe: %{
        "kind" => "legacy_routine_#{kind}",
        "name" => to_string(name)
      },
      prompt_assets: [
        %{
          "kind" => "module_function",
          "module" => "Custode.Routine.Prompts",
          "function" => "for_role/2",
          "role" => to_string(role)
        }
      ],
      executor_defaults: stringify(Map.take(defaults, @executor_fields)),
      budget_defaults: stringify(Map.take(defaults, @budget_fields)),
      limits: stringify(Map.take(defaults, @limit_fields)),
      provenance: %{
        "authority" => "declarative_config",
        "source" => to_string(kind),
        "name" => to_string(name),
        "known_role" => Roles.known?(role)
      }
    }

    version = "sha256:" <> digest(definition)
    {key, struct!(RoleTemplate, Map.put(definition, :version, version))}
  end

  defp defaults(declaration) do
    %{
      model: Application.fetch_env!(:custode, :model),
      effort: nil,
      timeout_ms: 200_000,
      max_turns: 20,
      hermetic: nil,
      agent: nil,
      mcp: false,
      max_budget_usd: Application.fetch_env!(:custode, :max_budget_usd),
      daily_budget_usd: Application.get_env(:custode, :daily_budget_usd),
      daily_budget_tokens: Application.get_env(:custode, :daily_budget_tokens),
      approved_args: %{"permission_mode" => "bypass_permissions"},
      extra_allowed_tools: []
    }
    |> Map.merge(Map.take(declaration, @executor_fields ++ @budget_fields ++ @limit_fields))
  end

  defp effective_role(role) when is_atom(role) do
    if Roles.known?(role), do: role, else: :assistant
  end

  defp effective_role(role) when is_binary(role) do
    role
    |> String.to_existing_atom()
    |> effective_role()
  rescue
    ArgumentError -> :assistant
  end

  defp effective_role(_role), do: :assistant

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp stringify(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), stringify(nested)} end)
  end

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when value in [nil, true, false], do: value
  defp stringify(value) when is_atom(value), do: to_string(value)
  defp stringify(value), do: value

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
