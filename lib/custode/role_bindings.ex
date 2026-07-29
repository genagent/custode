defmodule Custode.RoleBindings do
  @moduledoc """
  Live Mission RoleBindings and their one-way compatibility projection.

  Database-native bindings are mutable through typed operations. Fields on a
  legacy-derived binding are updated only by the legacy projector.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{Mission, Missions, Repo, RoleBinding, RoleTemplate, RoleTemplates}

  @spec list() :: [RoleBinding.t()]
  def list do
    RoleBinding
    |> Repo.all()
    |> Repo.preload(:mission)
  end

  @spec list_for_mission(String.t()) :: [RoleBinding.t()]
  def list_for_mission(mission_id) do
    case Missions.get(mission_id) do
      nil ->
        []

      mission ->
        from(binding in RoleBinding,
          where: binding.mission_id == ^mission.id,
          order_by: [asc: binding.key]
        )
        |> Repo.all()
        |> Repo.preload(:mission)
    end
  end

  @spec get(String.t()) :: RoleBinding.t() | nil
  def get(binding_id), do: RoleBinding |> Repo.get_by(binding_id: binding_id) |> preload()

  @spec get_by_legacy_routine(String.t()) :: RoleBinding.t() | nil
  def get_by_legacy_routine(legacy_routine_id) do
    RoleBinding
    |> Repo.get_by(legacy_routine_id: legacy_routine_id)
    |> preload()
  end

  @spec get_by_key(String.t(), String.t()) :: RoleBinding.t() | nil
  def get_by_key(mission_id, key) do
    with %Mission{} = mission <- Missions.get(mission_id) do
      RoleBinding
      |> Repo.get_by(mission_id: mission.id, key: key)
      |> preload()
    end
  end

  @doc false
  def create_database(attrs, actor) do
    attrs = atomize(attrs)

    with {:ok, mission} <- active_mission(attrs[:mission_id]),
         {:ok, template} <- template(attrs[:template_key]) do
      binding_attrs = %{
        binding_id: Ecto.UUID.generate(),
        mission_id: mission.id,
        key: attrs[:key],
        template_key: template.key,
        template_version: template.version,
        authority_source: "database",
        legacy_routine_id: nil,
        scoped_overrides: normalize(attrs[:scoped_overrides] || %{}),
        grants: normalize(attrs[:grants] || default_grants(template)),
        lifecycle: "active",
        provenance: %{
          "authority" => "database",
          "created_by" => normalize(actor),
          "template_version_at_creation" => template.version
        }
      }

      insert_database_binding(binding_attrs, attrs)
    end
  end

  @doc false
  def update_database(binding_id, attrs, actor) do
    attrs = atomize(attrs)

    with %RoleBinding{} = binding <- get(binding_id),
         :ok <- database_authority(binding),
         {:ok, _mission} <- active_mission(binding.mission.mission_id),
         {:ok, template} <- template(attrs[:template_key] || binding.template_key) do
      lifecycle = attrs[:lifecycle] || binding.lifecycle

      update_attrs = %{
        template_key: template.key,
        template_version: template.version,
        scoped_overrides: normalize(attrs[:scoped_overrides] || binding.scoped_overrides),
        grants: normalize(attrs[:grants] || binding.grants),
        lifecycle: lifecycle,
        retired_at: retired_at(lifecycle, binding.retired_at),
        provenance:
          Map.merge(binding.provenance, %{
            "last_updated_by" => normalize(actor),
            "template_version" => template.version
          })
      }

      binding
      |> RoleBinding.database_update_changeset(update_attrs)
      |> Repo.update()
      |> case do
        {:ok, updated} -> {:ok, preload(updated)}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, {:unknown_role_binding, binding_id}}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  def project_legacy(observation) do
    observation = normalize(observation)

    with :ok <- validate_projection(observation),
         {:ok, mission} <- active_mission(observation["mission_id"]),
         {:ok, template} <- template(observation["template_key"]),
         :ok <- current_template_version(template, observation["template_version"]) do
      case get_by_legacy_routine(observation["legacy_routine_id"]) do
        nil -> insert_projection(observation, mission)
        binding -> update_projection(binding, observation, mission)
      end
    end
  end

  @doc false
  def reconcile_legacy(observation) do
    observation = normalize(observation)
    observed_fingerprint = observation["projection_fingerprint"]

    case get_by_legacy_routine(observation["legacy_routine_id"]) do
      %RoleBinding{provenance: %{"projection_fingerprint" => fingerprint}} = binding
      when fingerprint == observed_fingerprint ->
        {:ok, %{binding: render(binding)},
         [binding_effect("legacy_role_binding_confirmed", binding)]}

      _missing_or_older ->
        :retry
    end
  end

  @spec render(RoleBinding.t()) :: map()
  def render(%RoleBinding{} = binding) do
    binding = preload(binding)

    %{
      binding_id: binding.binding_id,
      mission_id: binding.mission.mission_id,
      key: binding.key,
      template_key: binding.template_key,
      template_version: binding.template_version,
      authority_source: binding.authority_source,
      legacy_routine_id: binding.legacy_routine_id,
      scoped_overrides: binding.scoped_overrides,
      grants: binding.grants,
      lifecycle: binding.lifecycle,
      provenance: binding.provenance,
      retired_at: binding.retired_at && DateTime.to_iso8601(binding.retired_at)
    }
  end

  @doc """
  Immutable provenance payload for a future Attempt to copy at creation.

  The payload is deliberately a value, not a live association. Later template
  or binding changes therefore cannot rewrite an Attempt's recorded version.
  """
  @spec attempt_provenance(RoleBinding.t()) :: map()
  def attempt_provenance(%RoleBinding{} = binding) do
    %{
      "role_binding_id" => binding.binding_id,
      "role_template_key" => binding.template_key,
      "role_template_version" => binding.template_version,
      "authority_source" => binding.authority_source,
      "legacy_routine_id" => binding.legacy_routine_id
    }
  end

  defp insert_projection(observation, mission) do
    attrs = %{
      binding_id: Ecto.UUID.generate(),
      mission_id: mission.id,
      key: observation["key"],
      template_key: observation["template_key"],
      template_version: observation["template_version"],
      authority_source: "legacy_routine",
      legacy_routine_id: observation["legacy_routine_id"],
      scoped_overrides: observation["scoped_overrides"],
      grants: observation["grants"],
      lifecycle: "active",
      provenance: observation["provenance"]
    }

    case attrs |> RoleBinding.create_changeset() |> Repo.insert() do
      {:ok, binding} ->
        binding = preload(binding)
        {:ok, binding, [binding_effect("legacy_role_binding_created", binding)]}

      {:error, changeset} ->
        if unique_legacy_routine?(changeset) do
          project_legacy(observation)
        else
          {:error, changeset}
        end
    end
  end

  defp insert_database_binding(binding_attrs, attrs) do
    case binding_attrs |> RoleBinding.create_changeset() |> Repo.insert() do
      {:ok, binding} ->
        {:ok, {:created, preload(binding)}}

      {:error, changeset} ->
        handle_database_insert_error(changeset, attrs)
    end
  end

  defp handle_database_insert_error(changeset, attrs) do
    if unique_mission_key?(changeset) do
      case get_by_key(attrs[:mission_id], attrs[:key]) do
        %RoleBinding{authority_source: "database"} = binding ->
          {:ok, {:existing, binding}}

        %RoleBinding{} = binding ->
          {:error, {:binding_key_conflict, binding.binding_id}}

        nil ->
          {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp update_projection(binding, observation, mission) do
    cond do
      binding.authority_source != "legacy_routine" ->
        {:error, {:binding_authority_mismatch, binding.binding_id}}

      binding.mission_id != mission.id or binding.key != observation["key"] ->
        {:error,
         {:binding_identity_drift,
          %{
            binding_id: binding.binding_id,
            expected_mission_id: binding.mission.mission_id,
            observed_mission_id: mission.mission_id,
            expected_key: binding.key,
            observed_key: observation["key"]
          }}}

      true ->
        attrs = %{
          template_key: observation["template_key"],
          template_version: observation["template_version"],
          scoped_overrides: observation["scoped_overrides"],
          grants: observation["grants"],
          lifecycle: "active",
          retired_at: nil,
          provenance: observation["provenance"]
        }

        binding
        |> RoleBinding.legacy_projection_changeset(attrs)
        |> Repo.update()
        |> case do
          {:ok, updated} ->
            updated = preload(updated)
            {:ok, updated, [binding_effect("legacy_role_binding_updated", updated)]}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp validate_projection(observation) do
    required =
      ~w(legacy_routine_id mission_id key template_key template_version scoped_overrides grants provenance projection_fingerprint)

    valid? =
      Enum.all?(required, &Map.has_key?(observation, &1)) and
        Enum.all?(Enum.take(required, 5), &valid_string?(observation[&1])) and
        is_map(observation["scoped_overrides"]) and is_map(observation["grants"]) and
        is_map(observation["provenance"]) and valid_string?(observation["projection_fingerprint"]) and
        observation["provenance"]["authority"] == "legacy_routine" and
        observation["provenance"]["projection_fingerprint"] ==
          observation["projection_fingerprint"]

    if valid?,
      do: :ok,
      else: {:error, {:invalid_role_binding_projection, observation["legacy_routine_id"]}}
  end

  defp active_mission(mission_id) do
    case Missions.get(mission_id) do
      nil -> {:error, {:unknown_mission, mission_id}}
      %Mission{status: "archived"} -> {:error, :mission_archived}
      mission -> {:ok, mission}
    end
  end

  defp template(key) do
    case RoleTemplates.fetch(key) do
      {:ok, %RoleTemplate{} = template} -> {:ok, template}
      :error -> {:error, {:unknown_role_template, key}}
    end
  end

  defp current_template_version(%RoleTemplate{version: version}, version), do: :ok

  defp current_template_version(%RoleTemplate{version: expected}, observed),
    do: {:error, {:stale_role_template, %{expected: expected, observed: observed}}}

  defp database_authority(%RoleBinding{authority_source: "database"}), do: :ok

  defp database_authority(binding),
    do: {:error, {:read_only_legacy_binding, binding.binding_id}}

  defp default_grants(template) do
    %{
      "operation_grants" => template.operation_grants,
      "transport_allowlists" => template.transport_allowlists
    }
  end

  defp retired_at("retired", nil), do: DateTime.utc_now()
  defp retired_at("retired", retired_at), do: retired_at
  defp retired_at("active", _retired_at), do: nil
  defp retired_at(_invalid, retired_at), do: retired_at

  defp binding_effect(type, binding) do
    %{
      type: type,
      binding_id: binding.binding_id,
      mission_id: binding.mission.mission_id,
      template_key: binding.template_key,
      legacy_routine_id: binding.legacy_routine_id
    }
  end

  defp unique_legacy_routine?(changeset) do
    constraint_error?(changeset, :legacy_routine_id)
  end

  defp unique_mission_key?(changeset) do
    constraint_error?(changeset, :mission_id) or constraint_error?(changeset, :key)
  end

  defp constraint_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, options}} -> options[:constraint] == :unique
      _other -> false
    end)
  end

  defp valid_string?(value), do: is_binary(value) and value != ""

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {to_string(key), normalize(nested)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when value in [nil, true, false], do: value
  defp normalize(value) when is_atom(value), do: to_string(value)
  defp normalize(value), do: value

  defp atomize(value) when is_map(value) do
    Map.new(value, fn
      {key, nested} when is_binary(key) -> {String.to_existing_atom(key), nested}
      pair -> pair
    end)
  end

  defp preload(nil), do: nil
  defp preload(binding), do: Repo.preload(binding, :mission)
end
