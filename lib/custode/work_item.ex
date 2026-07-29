defmodule Custode.WorkItem do
  @moduledoc "Durable current truth for one desired outcome."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Artifact, Attempt, ContextBundle, Mission, WorkEvent, WorkGate}

  @states ~w(proposed ready active waiting blocked completed cancelled)

  schema "work_items" do
    field(:work_item_id, :string)
    belongs_to(:mission, Mission)
    belongs_to(:parent, __MODULE__)
    field(:kind, :string)
    field(:workflow_version, :integer)
    field(:objective, :string)
    field(:acceptance_criteria, :map)
    field(:state, :string, default: "proposed")
    field(:phase, :string)
    field(:priority, :integer, default: 0)
    field(:policy_ref, :string)
    field(:source, :string)
    field(:external_key, :string)
    field(:version, :integer, default: 1)
    field(:active_attempt_id, :string)
    field(:active_operation_call_id, :string)
    field(:waiting_condition, :map)
    field(:blocked_reason, :map)
    field(:outcome, :map)
    field(:completed_at, :utc_datetime_usec)
    field(:cancelled_at, :utc_datetime_usec)
    has_many(:events, WorkEvent)
    has_many(:gates, WorkGate)
    has_many(:attempts, Attempt)
    has_many(:context_bundles, ContextBundle)
    has_many(:artifacts, Artifact)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :work_item_id,
      :mission_id,
      :parent_id,
      :kind,
      :workflow_version,
      :objective,
      :acceptance_criteria,
      :state,
      :phase,
      :priority,
      :policy_ref,
      :source,
      :external_key,
      :version,
      :active_attempt_id,
      :active_operation_call_id,
      :waiting_condition,
      :blocked_reason,
      :outcome,
      :completed_at,
      :cancelled_at
    ])
    |> validate_required([
      :work_item_id,
      :mission_id,
      :kind,
      :workflow_version,
      :objective,
      :acceptance_criteria,
      :state,
      :phase,
      :priority,
      :source,
      :external_key,
      :version
    ])
    |> validate_inclusion(:state, @states)
    |> validate_number(:workflow_version, greater_than: 0)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> validate_number(:version, greater_than: 0)
    |> foreign_key_constraint(:mission_id)
    |> foreign_key_constraint(:parent_id)
    |> unique_constraint(:work_item_id)
    |> unique_constraint([:source, :external_key],
      name: :work_items_source_external_key_index
    )
  end
end
