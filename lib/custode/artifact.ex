defmodule Custode.Artifact do
  @moduledoc "Queryable metadata and provenance for file-backed or external evidence."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Attempt, Mission, WorkItem}

  schema "artifacts" do
    field(:artifact_id, :string)
    belongs_to(:producer_attempt, Attempt)
    belongs_to(:work_item, WorkItem)
    belongs_to(:mission, Mission)
    field(:kind, :string)
    field(:provenance, :map, default: %{})
    field(:external_identity, :string)
    field(:digest, :string)
    field(:media_type, :string)
    field(:location, :string)
    field(:size_bytes, :integer)
    field(:retention, :map, default: %{})
    field(:expires_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :artifact_id,
      :producer_attempt_id,
      :work_item_id,
      :mission_id,
      :kind,
      :provenance,
      :external_identity,
      :digest,
      :media_type,
      :location,
      :size_bytes,
      :retention,
      :expires_at
    ])
    |> validate_required([
      :artifact_id,
      :work_item_id,
      :mission_id,
      :kind,
      :provenance,
      :media_type,
      :location,
      :size_bytes,
      :retention
    ])
    |> validate_number(:size_bytes, greater_than_or_equal_to: 0)
    |> validate_identity()
    |> foreign_key_constraint(:producer_attempt_id)
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:mission_id)
    |> unique_constraint(:artifact_id)
    |> unique_constraint(:external_identity)
  end

  defp validate_identity(changeset) do
    external_identity = get_field(changeset, :external_identity)
    digest = get_field(changeset, :digest)

    if present?(external_identity) or present?(digest) do
      changeset
    else
      add_error(changeset, :digest, "or external_identity is required")
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
