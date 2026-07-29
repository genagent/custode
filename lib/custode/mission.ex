defmodule Custode.Mission do
  @moduledoc "Durable scope and continuity boundary for future work."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Artifact, ContextBundle, MissionTarget, WorkGate}

  schema "missions" do
    field(:mission_id, :string)
    field(:key, :string)
    field(:purpose, :string)
    field(:lifecycle, :string)
    field(:status, :string, default: "active")
    field(:policy_ref, :string)
    field(:budget_ref, :string)
    field(:context_ref, :string)
    field(:retention_seconds, :integer, default: 0)
    field(:metadata, :map, default: %{})
    field(:archived_at, :utc_datetime_usec)
    has_many(:targets, MissionTarget)
    has_many(:context_bundles, ContextBundle)
    has_many(:artifacts, Artifact)
    has_many(:work_gates, WorkGate)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :mission_id,
      :key,
      :purpose,
      :lifecycle,
      :status,
      :policy_ref,
      :budget_ref,
      :context_ref,
      :retention_seconds,
      :metadata
    ])
    |> validate_required([:mission_id, :key, :purpose, :lifecycle, :status])
    |> validate_inclusion(:lifecycle, ["persistent", "ephemeral"])
    |> validate_inclusion(:status, ["active", "archived"])
    |> validate_number(:retention_seconds, greater_than_or_equal_to: 0)
    |> unique_constraint(:mission_id)
    |> unique_constraint(:key)
  end

  def update_changeset(mission, attrs) do
    mission
    |> cast(attrs, [
      :purpose,
      :policy_ref,
      :budget_ref,
      :context_ref,
      :retention_seconds,
      :metadata,
      :status,
      :archived_at
    ])
    |> validate_required([:purpose, :status])
    |> validate_inclusion(:status, ["active", "archived"])
    |> validate_number(:retention_seconds, greater_than_or_equal_to: 0)
  end
end
