defmodule Custode.LegacyRoleBindingProjection do
  @moduledoc """
  One-way projection from legacy routine capability into live RoleBindings.

  Routines whose approved Mission strategy intentionally has no Mission
  (`reviewer` and `consistency` today) remain compatibility triggers and
  project only their declarative RoleTemplate.
  """

  alias Custode.{
    LegacyMissionProjection,
    RoleTemplates,
    Routine
  }

  alias Custode.Operations.RoleBindings.ProjectLegacyRoutine

  @binding_fields ~w(
    model effort timeout_ms max_turns hermetic agent mcp
    max_budget_usd daily_budget_usd daily_budget_tokens
    approved_args extra_allowed_tools
  )a

  @spec project_all(keyword()) :: {:ok, [map()]} | {:error, map()}
  def project_all(options \\ []) do
    routines = Keyword.get(options, :routines, Routine.all())
    correlation_id = Keyword.get(options, :correlation_id, Ecto.UUID.generate())

    mappings =
      options
      |> Keyword.get(:mission_mappings, LegacyMissionProjection.list())
      |> Map.new(&{&1.legacy_routine_id, &1})

    results =
      routines
      |> Enum.sort_by(&value(&1, :id))
      |> Enum.map(&project_routine(&1, mappings, correlation_id))

    failures = Enum.filter(results, &match?(%{result: {:error, _reason}}, &1))

    if failures == [] do
      {:ok, Enum.map(results, &unwrap_result/1)}
    else
      {:error,
       %{
         failures: Enum.map(failures, &failure/1),
         projected:
           results
           |> Enum.reject(&match?(%{result: {:error, _reason}}, &1))
           |> Enum.map(&unwrap_result/1)
       }}
    end
  end

  @doc """
  The boot entry point (#476): project what can be, warn about what cannot,
  never raise.
  """
  @spec project_at_boot() :: :ok
  def project_at_boot,
    do: Custode.BootProjection.run("legacy RoleBinding projection", fn -> project_all() end)

  @spec project_all!() :: :ok
  def project_all! do
    case project_all() do
      {:ok, _responses} ->
        :ok

      {:error, report} ->
        raise "legacy RoleBinding projection failed: #{inspect(report.failures)}"
    end
  end

  @spec observation(map(), String.t()) :: map()
  def observation(routine, mission_id) do
    template = RoleTemplates.for_routine(routine)
    legacy_routine_id = value(routine, :id)

    base = %{
      "legacy_routine_id" => legacy_routine_id,
      "mission_id" => mission_id,
      "key" => "legacy:routine:#{legacy_routine_id}",
      "template_key" => template.key,
      "template_version" => template.version,
      "scoped_overrides" => scoped_overrides(routine, template),
      "grants" => effective_grants(routine, template),
      "provenance" => %{
        "authority" => "legacy_routine",
        "legacy_routine_id" => legacy_routine_id,
        "configured_role" => to_string(value(routine, :role)),
        "profile" => optional_string(value(routine, :profile)),
        "prompt_asset" => %{
          "kind" => "legacy_composed_prompt",
          "digest" => digest(value(routine, :system_prompt))
        },
        "field_authority" => %{
          "template" => "declarative_config",
          "scoped_overrides" => "legacy_routine",
          "grants" => "legacy_routine",
          "lifecycle" => "legacy_projection"
        }
      }
    }

    fingerprint = digest(base)

    base
    |> put_in(["provenance", "projection_fingerprint"], fingerprint)
    |> Map.put("projection_fingerprint", fingerprint)
  end

  @spec fingerprint(map()) :: String.t()
  def fingerprint(observation), do: normalize(observation)["projection_fingerprint"]

  defp project_routine(routine, mappings, correlation_id) do
    legacy_routine_id = value(routine, :id)

    result =
      case Map.get(mappings, legacy_routine_id) do
        nil ->
          {:error, {:mission_mapping_required, legacy_routine_id}}

        %{mission: nil, strategy: strategy} ->
          template = RoleTemplates.for_routine(routine)

          {:ok,
           %{
             status: :template_only,
             legacy_routine_id: legacy_routine_id,
             strategy: strategy,
             template: RoleTemplates.render(template)
           }}

        %{mission: mission} ->
          routine
          |> observation(mission.mission_id)
          |> ProjectLegacyRoutine.dispatch(
            actor: %{kind: :system, id: "legacy-role-binding-projection"},
            transport: :system,
            correlation_id: correlation_id
          )
      end

    %{legacy_routine_id: legacy_routine_id, result: result}
  end

  defp scoped_overrides(routine, template) do
    defaults = RoleTemplates.effective_defaults(template)

    routine
    |> Map.take(@binding_fields)
    |> normalize()
    |> Enum.reject(fn {key, current} -> Map.get(defaults, key) == current end)
    |> Map.new()
  end

  defp effective_grants(routine, template) do
    mcp_tools =
      if value(routine, :mcp) do
        Routine.mcp_tools(value(routine, :role)) ++ Custode.MCP.external_allowed()
      else
        []
      end

    %{
      "operation_grants" => template.operation_grants,
      "mcp_tools" => Enum.sort(mcp_tools),
      "provider_tools" => value(routine, :extra_allowed_tools) || []
    }
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp failure(%{legacy_routine_id: id, result: {:error, reason}}),
    do: %{legacy_routine_id: id, reason: reason}

  defp unwrap_result(%{result: {:ok, response}}), do: response

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when value in [nil, true, false], do: value
  defp normalize(value) when is_atom(value), do: to_string(value)
  defp normalize(value), do: value

  defp digest(value) do
    value
    |> normalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
