defmodule Custode.AgentAuthorizationSnapshot do
  @moduledoc """
  Durable MCP authority captured for one routine execution revision.

  Provider processes and durable provider jobs name their exact execution
  revision. Keeping the small authority projection behind that revision lets
  an old turn retain its original role and filesystem/repository scope across
  coordinator or node restarts without reading a newer roster entry.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Repo, Roles}

  schema "agent_authorization_snapshots" do
    field(:routine_id, :string)
    field(:execution_revision, :string)
    field(:role, :string)
    field(:repo, :string)
    field(:workspace, :string)
    field(:working_dir, :string)
    timestamps(type: :utc_datetime_usec)
  end

  @fields [:routine_id, :execution_revision, :role, :repo, :workspace, :working_dir]

  @doc "Persist the authority projection for an exact execution revision."
  @spec put(map(), String.t()) ::
          :ok | {:error, Ecto.Changeset.t() | :snapshot_conflict}
  def put(routine, execution_revision)
      when is_map(routine) and is_binary(execution_revision) and execution_revision != "" do
    attrs = %{
      routine_id: value(routine, :id),
      execution_revision: execution_revision,
      role: routine |> value(:role, :assistant) |> to_string(),
      repo: value(routine, :repo),
      workspace: value(routine, :workspace),
      working_dir: value(routine, :working_dir)
    }

    case Repo.get_by(__MODULE__,
           routine_id: attrs.routine_id,
           execution_revision: attrs.execution_revision
         ) do
      nil -> insert(attrs)
      snapshot -> verify_immutable(snapshot, attrs)
    end
  end

  @doc "Read the authority projection captured for an exact execution revision."
  @spec get(String.t(), String.t()) :: map() | nil | {:error, {:unknown_role, String.t()}}
  def get(routine_id, execution_revision)
      when is_binary(routine_id) and is_binary(execution_revision) do
    case Repo.get_by(__MODULE__, routine_id: routine_id, execution_revision: execution_revision) do
      nil ->
        nil

      snapshot ->
        case role_atom(snapshot.role) do
          {:ok, role} ->
            %{
              id: snapshot.routine_id,
              execution_revision: snapshot.execution_revision,
              role: role,
              repo: snapshot.repo,
              workspace: snapshot.workspace,
              working_dir: snapshot.working_dir
            }

          :error ->
            {:error, {:unknown_role, snapshot.role}}
        end
    end
  end

  defp insert(attrs) do
    result =
      %__MODULE__{}
      |> changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:routine_id, :execution_revision]
      )

    case result do
      # A concurrent writer may have won after the read above. Fetching the
      # durable winner keeps the revision immutable in both cases.
      {:ok, _snapshot} -> verify_immutable(attrs)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp verify_immutable(attrs) do
    snapshot =
      Repo.get_by!(__MODULE__,
        routine_id: attrs.routine_id,
        execution_revision: attrs.execution_revision
      )

    verify_immutable(snapshot, attrs)
  end

  defp verify_immutable(snapshot, attrs) do
    if Map.take(snapshot, @fields) == attrs,
      do: :ok,
      else: {:error, :snapshot_conflict}
  end

  defp changeset(snapshot, attrs) do
    snapshot
    |> cast(attrs, @fields)
    |> validate_required([
      :routine_id,
      :execution_revision,
      :role,
      :workspace,
      :working_dir
    ])
    |> unique_constraint([:routine_id, :execution_revision])
  end

  defp role_atom(role) do
    case Enum.find(Map.keys(Roles.all()), &(Atom.to_string(&1) == role)) do
      nil -> :error
      role -> {:ok, role}
    end
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end
end
