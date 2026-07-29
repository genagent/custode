defmodule Custode.OperationCall do
  @moduledoc "Durable record of one logical command invocation."

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(proposed waiting running succeeded failed denied stale cancelled)

  schema "operation_calls" do
    field(:call_id, :string)
    field(:operation, :string)
    field(:arguments, :map)
    field(:actor, :map)
    field(:transport, :string)
    field(:authorization_result, :map)
    field(:grant, :string)
    field(:risk, :string)
    field(:idempotency_scope, :string)
    field(:idempotency_key, :string)
    field(:expected_versions, :map)
    field(:preconditions, :map)
    field(:correlation_id, :string)
    field(:causation_id, :string)
    field(:mission_id, :string)
    field(:work_item_id, :string)
    field(:attempt_id, :string)
    field(:dry_run, :boolean, default: false)
    field(:effect_preview, :map)
    field(:result, :map)
    field(:effects, :map)
    field(:error, :map)
    field(:status, :string)
    field(:lease_token, :string)
    field(:lease_expires_at, :utc_datetime_usec)
    field(:started_at, :utc_datetime_usec)
    field(:finished_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :call_id,
      :operation,
      :arguments,
      :actor,
      :transport,
      :risk,
      :idempotency_scope,
      :idempotency_key,
      :expected_versions,
      :preconditions,
      :correlation_id,
      :causation_id,
      :mission_id,
      :work_item_id,
      :attempt_id,
      :dry_run,
      :status,
      :lease_token,
      :lease_expires_at
    ])
    |> validate_required([
      :call_id,
      :operation,
      :arguments,
      :actor,
      :transport,
      :risk,
      :idempotency_scope,
      :idempotency_key,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:operation, :idempotency_scope, :idempotency_key],
      name: :operation_calls_operation_idempotency_scope_idempotency_key_index
    )
    |> unique_constraint(:call_id)
  end

  @doc false
  def update_changeset(call, attrs) do
    call
    |> cast(attrs, [
      :authorization_result,
      :grant,
      :preconditions,
      :effect_preview,
      :result,
      :effects,
      :error,
      :status,
      :lease_token,
      :lease_expires_at,
      :started_at,
      :finished_at
    ])
    |> validate_inclusion(:status, @statuses)
  end
end
