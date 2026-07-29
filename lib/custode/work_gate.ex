defmodule Custode.WorkGate do
  @moduledoc "A durable decision over one exact work-scoped operation preview."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Attempt, Mission, WorkItem}

  @statuses ~w(open approved rejected stale cancelled superseded)
  @subject_kinds ~w(transition operation_call)

  schema "work_gates" do
    field(:gate_id, :string)
    belongs_to(:mission, Mission)
    belongs_to(:work_item, WorkItem)
    belongs_to(:attempt, Attempt)
    field(:operation_call_id, :string)
    field(:subject_kind, :string)
    field(:operation, :string)
    field(:arguments, :map)
    field(:preview, :map)
    field(:requester, :map)
    field(:resolver, :map)
    field(:status, :string, default: "open")
    field(:resolution, :map)
    field(:reason, :map)
    field(:work_item_version, :integer)
    field(:policy_version, :string)
    field(:grant_decision, :map)
    field(:external_preconditions, :map, default: %{})
    field(:definition_fingerprint, :string)
    field(:operation_idempotency_key, :string)
    field(:correlation_id, :string)
    field(:causation_id, :string)
    field(:resolved_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :gate_id,
      :mission_id,
      :work_item_id,
      :subject_kind,
      :operation,
      :arguments,
      :preview,
      :requester,
      :status,
      :work_item_version,
      :policy_version,
      :grant_decision,
      :external_preconditions,
      :definition_fingerprint,
      :operation_idempotency_key
    ])
    |> validate_inclusion(:status, ["open"])
    |> validate_inclusion(:subject_kind, @subject_kinds)
    |> validate_number(:work_item_version, greater_than: 0)
    |> foreign_key_constraint(:mission_id)
    |> foreign_key_constraint(:work_item_id)
    |> foreign_key_constraint(:attempt_id)
    |> foreign_key_constraint(:operation_call_id)
    |> unique_constraint(:gate_id)
    |> unique_constraint(:operation_call_id)
  end

  @doc false
  def resolve_changeset(gate, attrs) do
    gate
    |> cast(attrs, [
      :operation_call_id,
      :resolver,
      :status,
      :resolution,
      :reason,
      :resolved_at
    ])
    |> validate_required([:resolver, :status, :resolution, :resolved_at])
    |> validate_inclusion(:status, @statuses -- ["open"])
    |> foreign_key_constraint(:operation_call_id)
    |> unique_constraint(:operation_call_id)
  end

  def statuses, do: @statuses

  defp fields do
    [
      :gate_id,
      :mission_id,
      :work_item_id,
      :attempt_id,
      :operation_call_id,
      :subject_kind,
      :operation,
      :arguments,
      :preview,
      :requester,
      :resolver,
      :status,
      :resolution,
      :reason,
      :work_item_version,
      :policy_version,
      :grant_decision,
      :external_preconditions,
      :definition_fingerprint,
      :operation_idempotency_key,
      :correlation_id,
      :causation_id,
      :resolved_at
    ]
  end
end
