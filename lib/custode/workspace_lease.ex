defmodule Custode.WorkspaceLease do
  @moduledoc "Durable ownership of one contained repository workspace and landing scope."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Attempt, Mission, WorkItem}

  @states ~w(acquiring active stale released cleanup_failed)
  @cleanup_states ~w(pending retained cleaned failed)

  schema "workspace_leases" do
    field(:lease_id, :string)
    belongs_to(:mission, Mission)
    belongs_to(:work_item, WorkItem)
    belongs_to(:attempt, Attempt)
    field(:repository_id, :string)
    field(:repository_path, :string)
    field(:workspace_identity, :string)
    field(:workspace_path, :string)
    field(:branch, :string)
    field(:base_ref, :string)
    field(:expected_base_revision, :string)
    field(:observed_base_revision, :string)
    field(:landing_scope, :string)
    field(:state, :string, default: "acquiring")
    field(:cleanup_state, :string, default: "pending")
    field(:provenance, :map, default: %{})
    field(:acquired_at, :utc_datetime_usec)
    field(:heartbeat_at, :utc_datetime_usec)
    field(:expires_at, :utc_datetime_usec)
    field(:prepared_at, :utc_datetime_usec)
    field(:released_at, :utc_datetime_usec)
    field(:cleanup_error, :map)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :lease_id,
      :mission_id,
      :work_item_id,
      :attempt_id,
      :repository_id,
      :repository_path,
      :workspace_identity,
      :workspace_path,
      :branch,
      :base_ref,
      :expected_base_revision,
      :landing_scope,
      :state,
      :cleanup_state,
      :provenance,
      :acquired_at,
      :heartbeat_at,
      :expires_at
    ])
    |> validate_inclusion(:state, ["acquiring"])
    |> validate_inclusion(:cleanup_state, ["pending"])
    |> apply_constraints()
  end

  def update_changeset(lease, attrs) do
    lease
    |> cast(attrs, [
      :state,
      :cleanup_state,
      :observed_base_revision,
      :heartbeat_at,
      :expires_at,
      :prepared_at,
      :released_at,
      :cleanup_error,
      :provenance
    ])
    |> validate_inclusion(:state, @states)
    |> validate_inclusion(:cleanup_state, @cleanup_states)
    |> apply_constraints()
  end

  defp fields do
    [
      :lease_id,
      :mission_id,
      :work_item_id,
      :attempt_id,
      :repository_id,
      :repository_path,
      :workspace_identity,
      :workspace_path,
      :branch,
      :base_ref,
      :expected_base_revision,
      :observed_base_revision,
      :landing_scope,
      :state,
      :cleanup_state,
      :provenance,
      :acquired_at,
      :heartbeat_at,
      :expires_at,
      :prepared_at,
      :released_at,
      :cleanup_error
    ]
  end

  defp apply_constraints(changeset) do
    changeset
    |> foreign_key_constraint(:mission_id)
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:attempt_id)
    |> unique_constraint(:lease_id)
    |> unique_constraint(:attempt_id)
    |> unique_constraint(:work_item_id, name: :workspace_leases_live_work_item_index)
    |> unique_constraint(:work_item_id, name: :workspace_leases_work_item_id_index)
    |> unique_constraint(:landing_scope, name: :workspace_leases_live_landing_scope_index)
    |> unique_constraint(:landing_scope, name: :workspace_leases_landing_scope_index)
    |> unique_constraint(:workspace_path, name: :workspace_leases_live_path_index)
    |> unique_constraint(:workspace_path, name: :workspace_leases_workspace_path_index)
  end
end
