defmodule Custode.ConversationArc do
  @moduledoc "Durable, provider-neutral identity for one bounded conversation or work arc."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.ConversationArcEvent

  @states ~w(active completed rotated)
  @kinds ~w(operator scheduled specialist job attempt inbox)

  schema "conversation_arcs" do
    field(:routine_id, :string)
    field(:arc_id, :string)
    field(:logical_id, :string)
    field(:kind, :string)
    field(:provider, :string)
    field(:provider_session_id, :string)
    field(:host_id, :string)
    field(:workspace_identity, :string)
    field(:configuration_fingerprint, :string)
    belongs_to(:parent, __MODULE__)
    field(:state, :string, default: "active")
    field(:last_decision, :string)
    field(:last_reason, :string)
    field(:last_outcome, :string)
    field(:rotation_reason, :string)
    field(:opened_at, :utc_datetime_usec)
    field(:last_used_at, :utc_datetime_usec)
    field(:closed_at, :utc_datetime_usec)
    has_many(:events, ConversationArcEvent)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :routine_id,
      :arc_id,
      :logical_id,
      :kind,
      :provider,
      :host_id,
      :workspace_identity,
      :configuration_fingerprint,
      :state,
      :last_decision,
      :last_reason,
      :opened_at,
      :last_used_at
    ])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:routine_id, :logical_id],
      name: :conversation_arcs_active_identity_index
    )
    |> unique_constraint([:routine_id, :arc_id])
    |> foreign_key_constraint(:parent_id)
  end

  def update_changeset(arc, attrs) do
    arc
    |> cast(attrs, fields())
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:routine_id, :logical_id],
      name: :conversation_arcs_active_identity_index
    )
    |> unique_constraint([:routine_id, :arc_id])
    |> foreign_key_constraint(:parent_id)
  end

  defp fields do
    [
      :routine_id,
      :arc_id,
      :logical_id,
      :kind,
      :provider,
      :provider_session_id,
      :host_id,
      :workspace_identity,
      :configuration_fingerprint,
      :parent_id,
      :state,
      :last_decision,
      :last_reason,
      :last_outcome,
      :rotation_reason,
      :opened_at,
      :last_used_at,
      :closed_at
    ]
  end
end
