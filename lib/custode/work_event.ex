defmodule Custode.WorkEvent do
  @moduledoc "Append-only typed account of WorkItem lifecycle, gates, and process decisions."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Mission, WorkItem}

  schema "work_events" do
    field(:event_id, :string)
    belongs_to(:work_item, WorkItem)
    belongs_to(:mission, Mission)
    field(:kind, :string)
    field(:actor, :map)
    field(:operation, :string)
    field(:operation_call_id, :string)
    field(:gate_id, :string)
    field(:before_state, :string)
    field(:before_phase, :string)
    field(:after_state, :string)
    field(:after_phase, :string)
    field(:before_version, :integer)
    field(:work_item_version, :integer)
    field(:evidence, :map, default: %{})
    field(:correlation_id, :string)
    field(:causation_id, :string)
    timestamps(updated_at: false, type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :event_id,
      :work_item_id,
      :mission_id,
      :kind,
      :actor,
      :operation,
      :operation_call_id,
      :gate_id,
      :before_state,
      :before_phase,
      :after_state,
      :after_phase,
      :before_version,
      :work_item_version,
      :evidence,
      :correlation_id,
      :causation_id
    ])
    |> validate_required([
      :event_id,
      :work_item_id,
      :mission_id,
      :kind,
      :actor,
      :operation,
      :after_state,
      :after_phase,
      :work_item_version
    ])
    |> validate_inclusion(:kind, [
      "work_item.created",
      "work_item.transitioned",
      "work_item.reopened",
      "gate.rejected",
      "gate.stale",
      "work.next_action.claimed",
      "work.next_action.completed"
    ])
    |> validate_number(:work_item_version, greater_than: 0)
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:mission_id)
    |> unique_constraint(:event_id)
    |> unique_constraint(:operation_call_id)
    |> unique_constraint([:work_item_id, :work_item_version],
      name: :work_events_next_action_claim_index
    )
    # SQLite reports partial-index conflicts by the default field-derived
    # constraint name rather than the explicit index name.
    |> unique_constraint([:work_item_id, :work_item_version],
      name: :work_events_work_item_id_work_item_version_index
    )
    |> unique_constraint(:causation_id, name: :work_events_next_action_result_index)
    |> unique_constraint(:causation_id, name: :work_events_causation_id_index)
    |> foreign_key_constraint(:gate_id)
    |> unique_constraint(:gate_id)
  end
end
