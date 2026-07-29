defmodule Custode.ContextBundle do
  @moduledoc "Durable identity and digest for one reproducible execution dossier."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Artifact, Mission, WorkItem}

  schema "context_bundles" do
    field(:context_bundle_id, :string)
    belongs_to(:work_item, WorkItem)
    belongs_to(:mission, Mission)
    belongs_to(:artifact, Artifact)
    field(:version, :integer, default: 1)
    field(:digest, :string)
    field(:component_digests, :map)
    field(:provenance, :map, default: %{})
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :context_bundle_id,
      :work_item_id,
      :mission_id,
      :artifact_id,
      :version,
      :digest,
      :component_digests,
      :provenance
    ])
    |> validate_required([
      :context_bundle_id,
      :work_item_id,
      :mission_id,
      :artifact_id,
      :version,
      :digest,
      :component_digests,
      :provenance
    ])
    |> validate_number(:version, greater_than: 0)
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:mission_id)
    |> foreign_key_constraint(:artifact_id)
    |> unique_constraint(:context_bundle_id)
    |> unique_constraint([:work_item_id, :digest],
      name: :context_bundles_work_item_id_digest_index
    )
  end
end
