defmodule Custode.LegacyMissionProjection do
  @moduledoc """
  Deterministic, one-way projection from legacy routines to Mission scope.

  Repository routines resolve mutable owner/name references to GitHub's stable
  repository ID. An established mapping is never moved to another identity:
  changed identity is persisted as an exception, while a rename at the same
  ID updates only the Mission target projection.
  """

  alias Custode.{
    LegacyRoutineMissionMapping,
    Mission,
    Missions,
    Repo,
    Routine
  }

  alias Custode.Operations.Missions.ProjectLegacyRoutine

  @global_strategies ~w(repository_attempts ephemeral_per_investigation)
  @mission_strategies ~w(repository fixed_mission)

  @spec list() :: [LegacyRoutineMissionMapping.t()]
  def list do
    LegacyRoutineMissionMapping
    |> Repo.all()
    |> Repo.preload(mission: :targets)
  end

  @spec get_by_routine(String.t()) :: LegacyRoutineMissionMapping.t() | nil
  def get_by_routine(legacy_routine_id) do
    LegacyRoutineMissionMapping
    |> Repo.get_by(legacy_routine_id: legacy_routine_id)
    |> preload()
  end

  @spec project_all(keyword()) :: {:ok, [map()]} | {:error, map()}
  def project_all(options \\ []) do
    routines = Keyword.get(options, :routines, Routine.all())

    seeds =
      Keyword.get(options, :seeds, Application.get_env(:custode, :legacy_mission_mappings, %{}))

    resolver =
      Keyword.get(
        options,
        :repository_identity,
        Application.get_env(
          :custode,
          :repository_identity,
          Custode.GitHub.RepositoryIdentity
        )
      )

    correlation_id = Keyword.get(options, :correlation_id, Ecto.UUID.generate())
    identities = resolve_repositories(routines, resolver)

    results =
      routines
      |> Enum.sort_by(&routine_value(&1, :id))
      |> Enum.map(&project_routine(&1, seeds, identities, correlation_id))

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

  @spec project_all!() :: :ok
  def project_all! do
    case project_all() do
      {:ok, _responses} ->
        :ok

      {:error, report} ->
        raise "legacy Mission projection failed: #{inspect(report.failures)}"
    end
  end

  @doc false
  def project(observation) do
    observation = normalize(observation)

    with :ok <- validate_observation(observation) do
      fingerprint = fingerprint(observation)
      legacy_routine_id = observation["legacy_routine_id"]

      case get_by_routine(legacy_routine_id) do
        nil -> create_mapping(observation, fingerprint)
        mapping -> observe_mapping(mapping, observation, fingerprint)
      end
    end
  end

  @doc false
  def reconcile(observation) do
    observation = normalize(observation)
    fingerprint = fingerprint(observation)

    case get_by_routine(observation["legacy_routine_id"]) do
      %{last_observed_fingerprint: ^fingerprint} = mapping ->
        {:ok, %{mapping: render(mapping)}, [reconcile_effect(mapping)]}

      _missing_or_older ->
        :retry
    end
  end

  @doc false
  def fingerprint(observation) do
    observation
    |> normalize()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @spec render(LegacyRoutineMissionMapping.t()) :: map()
  def render(%LegacyRoutineMissionMapping{} = mapping) do
    mapping = preload(mapping)

    %{
      mapping_id: mapping.mapping_id,
      legacy_routine_id: mapping.legacy_routine_id,
      mission_id: mapping.mission && mapping.mission.mission_id,
      strategy: mapping.strategy,
      mapping_identity: mapping.mapping_identity,
      status: mapping.status,
      source_snapshot: mapping.source_snapshot,
      last_observed_snapshot: mapping.last_observed_snapshot,
      exception: mapping.exception
    }
  end

  defp project_routine(routine, seeds, identities, correlation_id) do
    legacy_routine_id = routine_value(routine, :id)

    result =
      with {:ok, observation} <- observation(routine, seeds, identities) do
        ProjectLegacyRoutine.dispatch(observation,
          actor: %{kind: :system, id: "legacy-mission-projection"},
          transport: :system,
          correlation_id: correlation_id
        )
      end

    %{legacy_routine_id: legacy_routine_id, result: result}
  end

  defp observation(routine, seeds, identities) do
    legacy_routine_id = routine_value(routine, :id)

    case routine_value(routine, :repo) do
      repo when is_binary(repo) ->
        case Map.fetch!(identities, repo) do
          {:ok, identity} -> {:ok, repository_observation(legacy_routine_id, repo, identity)}
          {:error, reason} -> {:error, {:repository_identity_unavailable, repo, reason}}
        end

      _no_repository ->
        case seed(seeds, legacy_routine_id) do
          nil -> {:error, {:explicit_mapping_required, legacy_routine_id}}
          declaration -> seed_observation(legacy_routine_id, declaration)
        end
    end
  end

  defp repository_observation(legacy_routine_id, configured_name, identity) do
    repository_id = to_string(identity.id)
    canonical_name = identity.name_with_owner

    %{
      "legacy_routine_id" => legacy_routine_id,
      "strategy" => "repository",
      "mapping_identity" => "github_repository:#{repository_id}",
      "source" => %{
        "kind" => "legacy_routine_repository",
        "configured_name" => configured_name,
        "repository_id" => repository_id,
        "canonical_name" => canonical_name
      },
      "mission" => %{
        "key" => "github:repository:#{repository_id}",
        "purpose" => "Operate #{canonical_name}",
        "lifecycle" => "persistent",
        "targets" => [
          %{
            "kind" => "github_repository",
            "external_id" => repository_id,
            "display_name" => canonical_name
          }
        ]
      }
    }
  end

  defp seed_observation(legacy_routine_id, declaration) do
    declaration = normalize(declaration)
    strategy = declaration["strategy"]

    cond do
      strategy == "fixed_mission" and is_map(declaration["mission"]) ->
        mission = declaration["mission"]

        {:ok,
         %{
           "legacy_routine_id" => legacy_routine_id,
           "strategy" => strategy,
           "mapping_identity" => "mission:#{mission["key"]}",
           "source" => %{
             "kind" => "explicit_seed",
             "seed_id" => legacy_routine_id,
             "mission_key" => mission["key"]
           },
           "mission" => mission
         }}

      strategy in @global_strategies and is_nil(declaration["mission"]) ->
        {:ok,
         %{
           "legacy_routine_id" => legacy_routine_id,
           "strategy" => strategy,
           "mapping_identity" => "strategy:#{strategy}",
           "source" => %{
             "kind" => "explicit_seed",
             "seed_id" => legacy_routine_id
           }
         }}

      true ->
        {:error, {:invalid_mapping_seed, legacy_routine_id}}
    end
  end

  defp create_mapping(observation, fingerprint) do
    with {:ok, mission, mission_effects} <- ensure_mission(observation),
         {:ok, mapping} <-
           observation
           |> mapping_attrs(fingerprint, mission)
           |> LegacyRoutineMissionMapping.create_changeset()
           |> Repo.insert() do
      mapping = preload(mapping)
      effect = mapping_effect("legacy_routine_mapped", mapping)
      {:ok, mapping, mission_effects ++ [effect]}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        if unique_routine?(changeset) do
          project(observation)
        else
          {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp observe_mapping(mapping, observation, fingerprint) do
    if mapping_matches?(mapping, observation) do
      confirm_mapping(mapping, observation, fingerprint)
    else
      record_drift(mapping, observation, fingerprint)
    end
  end

  defp confirm_mapping(mapping, observation, fingerprint) do
    with {:ok, renamed?} <- maybe_update_repository_projection(mapping, observation),
         {:ok, mapping} <-
           mapping
           |> LegacyRoutineMissionMapping.observe_changeset(%{
             status: "active",
             last_observed_snapshot: observation,
             last_observed_fingerprint: fingerprint,
             exception: nil
           })
           |> Repo.update() do
      mapping = preload(mapping, true)

      type =
        if renamed?,
          do: "legacy_repository_projection_updated",
          else: "legacy_routine_mapping_confirmed"

      {:ok, mapping, [mapping_effect(type, mapping)]}
    end
  end

  defp record_drift(mapping, observation, fingerprint) do
    exception = %{
      "type" => "mapping_drift",
      "expected" => %{
        "strategy" => mapping.strategy,
        "mapping_identity" => mapping.mapping_identity
      },
      "observed" => %{
        "strategy" => observation["strategy"],
        "mapping_identity" => observation["mapping_identity"]
      }
    }

    mapping
    |> LegacyRoutineMissionMapping.observe_changeset(%{
      status: "exception",
      last_observed_snapshot: observation,
      last_observed_fingerprint: fingerprint,
      exception: exception
    })
    |> Repo.update()
    |> case do
      {:ok, mapping} ->
        mapping = preload(mapping, true)
        {:ok, mapping, [mapping_effect("legacy_routine_mapping_drifted", mapping)]}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_mission(%{"strategy" => strategy, "mission" => mission})
       when strategy in @mission_strategies do
    case Missions.create(mission_attrs(mission)) do
      {:ok, {:created, mission}} ->
        {:ok, mission, [%{type: "mission_created", mission_id: mission.mission_id}]}

      {:ok, {:existing, mission}} ->
        {:ok, mission, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_mission(%{"strategy" => strategy}) when strategy in @global_strategies,
    do: {:ok, nil, []}

  defp maybe_update_repository_projection(
         %{strategy: "repository", mission: %Mission{} = mission},
         observation
       ) do
    target = observation |> get_in(["mission", "targets"]) |> List.first()

    current =
      Enum.find(mission.targets, fn existing ->
        existing.kind == target["kind"] and existing.external_id == target["external_id"]
      end)

    if current && current.display_name != target["display_name"] do
      case Missions.update(mission.mission_id, %{target: target_attrs(target)}) do
        {:ok, _mission} -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  defp maybe_update_repository_projection(_mapping, _observation), do: {:ok, false}

  defp mapping_attrs(observation, fingerprint, mission) do
    %{
      mapping_id: Ecto.UUID.generate(),
      legacy_routine_id: observation["legacy_routine_id"],
      mission_id: mission && mission.id,
      strategy: observation["strategy"],
      mapping_identity: observation["mapping_identity"],
      status: "active",
      source_snapshot: observation,
      last_observed_snapshot: observation,
      last_observed_fingerprint: fingerprint
    }
  end

  defp mission_attrs(mission) do
    %{
      key: mission["key"],
      purpose: mission["purpose"],
      lifecycle: mission["lifecycle"],
      targets: Enum.map(mission["targets"], &target_attrs/1),
      policy_ref: mission["policy_ref"],
      budget_ref: mission["budget_ref"],
      context_ref: mission["context_ref"],
      retention_seconds: mission["retention_seconds"] || 0,
      metadata: mission["metadata"] || %{}
    }
  end

  defp target_attrs(target) do
    %{
      kind: target["kind"],
      external_id: target["external_id"],
      display_name: target["display_name"],
      metadata: target["metadata"] || %{}
    }
  end

  defp mapping_matches?(mapping, observation) do
    mapping.strategy == observation["strategy"] and
      mapping.mapping_identity == observation["mapping_identity"]
  end

  defp validate_observation(
         %{
           "legacy_routine_id" => legacy_routine_id,
           "strategy" => "repository",
           "mapping_identity" => mapping_identity,
           "source" => source,
           "mission" => mission
         } = observation
       ) do
    valid? =
      valid_string?(legacy_routine_id) and is_map(source) and is_map(mission) and
        valid_repository_projection?(mapping_identity, source, mission)

    if valid?, do: :ok, else: invalid_observation(observation)
  end

  defp validate_observation(
         %{
           "legacy_routine_id" => legacy_routine_id,
           "strategy" => "fixed_mission",
           "mapping_identity" => mapping_identity,
           "source" => source,
           "mission" => mission
         } = observation
       ) do
    valid? =
      valid_string?(legacy_routine_id) and is_map(source) and is_map(mission) and
        valid_fixed_projection?(mapping_identity, mission)

    if valid?, do: :ok, else: invalid_observation(observation)
  end

  defp validate_observation(
         %{
           "legacy_routine_id" => legacy_routine_id,
           "strategy" => strategy,
           "mapping_identity" => mapping_identity,
           "source" => source
         } = observation
       )
       when strategy in @global_strategies do
    valid? =
      valid_string?(legacy_routine_id) and is_map(source) and
        mapping_identity == "strategy:#{strategy}" and not Map.has_key?(observation, "mission")

    if valid?, do: :ok, else: invalid_observation(observation)
  end

  defp validate_observation(observation), do: invalid_observation(observation)

  defp invalid_observation(observation) do
    {:error,
     {:invalid_projection,
      %{
        legacy_routine_id: observation["legacy_routine_id"],
        strategy: observation["strategy"]
      }}}
  end

  defp valid_repository_projection?(mapping_identity, source, mission) do
    repository_id = source["repository_id"]
    canonical_name = source["canonical_name"]

    case mission["targets"] do
      [target] ->
        valid_string?(repository_id) and valid_string?(canonical_name) and
          mapping_identity == "github_repository:#{repository_id}" and
          mission["key"] == "github:repository:#{repository_id}" and
          mission["lifecycle"] == "persistent" and
          repository_target?(target, repository_id, canonical_name)

      _invalid_targets ->
        false
    end
  end

  defp valid_fixed_projection?(mapping_identity, mission) do
    valid_string?(mission["key"]) and mapping_identity == "mission:#{mission["key"]}" and
      mission["lifecycle"] == "persistent" and
      is_list(mission["targets"]) and mission["targets"] != []
  end

  defp repository_target?(target, repository_id, canonical_name) when is_map(target) do
    target["kind"] == "github_repository" and target["external_id"] == repository_id and
      target["display_name"] == canonical_name
  end

  defp repository_target?(_target, _repository_id, _canonical_name), do: false
  defp valid_string?(value), do: is_binary(value) and value != ""

  defp mapping_effect(type, mapping) do
    %{
      type: type,
      mapping_id: mapping.mapping_id,
      legacy_routine_id: mapping.legacy_routine_id,
      mission_id: mapping.mission && mapping.mission.mission_id,
      strategy: mapping.strategy,
      status: mapping.status
    }
  end

  defp reconcile_effect(%{status: "exception"} = mapping),
    do: mapping_effect("legacy_routine_mapping_drifted", mapping)

  defp reconcile_effect(mapping),
    do: mapping_effect("legacy_routine_mapping_confirmed", mapping)

  defp resolve_repositories(routines, resolver) do
    routines
    |> Enum.map(&routine_value(&1, :repo))
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, resolver.resolve(&1)})
  end

  defp seed(seeds, id) do
    Map.get(seeds, id) ||
      Enum.find_value(seeds, fn {key, value} -> if to_string(key) == id, do: value end)
  end

  defp routine_value(routine, key) when is_map(routine),
    do: Map.get(routine, key) || Map.get(routine, Atom.to_string(key))

  defp failure(%{legacy_routine_id: id, result: {:error, reason}}),
    do: %{legacy_routine_id: id, reason: reason}

  defp unwrap_result(%{result: {:ok, response}}), do: response

  defp unique_routine?(changeset) do
    Enum.any?(changeset.errors, fn
      {:legacy_routine_id, {_message, options}} -> options[:constraint] == :unique
      _other -> false
    end)
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when value in [nil, true, false], do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value), do: value

  defp preload(mapping, force \\ false)
  defp preload(nil, _force), do: nil

  defp preload(mapping, force),
    do: Repo.preload(mapping, [mission: :targets], force: force)
end
