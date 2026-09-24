defmodule Custode.OperatorMessage do
  @moduledoc "A durable operator or delegated message and its exact provider outcome."

  use Ecto.Schema

  import Ecto.Changeset

  @statuses ~w(queued executing waiting_for_input waiting_for_approval completed failed refused)

  schema "operator_messages" do
    field(:message_id, :string)
    field(:caller_kind, :string)
    field(:caller_id, :string)
    field(:transport, :string)
    field(:target_agent_id, :string)
    field(:idempotency_key, :string)
    field(:prompt_hash, :string)
    field(:prompt, :string)
    field(:provider_correlation_id, :string)
    field(:continues_message_id, :string)
    field(:status, :string, default: "queued")
    field(:delivery, :string)
    field(:provider, :string)
    field(:agent_generation, :string)
    field(:agent_turn_id, :string)
    field(:arc_id, :string)
    field(:provider_session_id, :string)
    field(:detail, :string)
    field(:result, :map)
    field(:error, :map)
    field(:started_at, :utc_datetime_usec)
    field(:completed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_required([
      :message_id,
      :caller_kind,
      :caller_id,
      :transport,
      :target_agent_id,
      :idempotency_key,
      :prompt_hash,
      :prompt,
      :provider_correlation_id,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:message_id)
    |> unique_constraint([:caller_kind, :caller_id, :target_agent_id, :idempotency_key],
      name: :operator_messages_idempotency_index
    )
  end

  def update_changeset(message, attrs) do
    message
    |> cast(attrs, fields())
    |> validate_inclusion(:status, @statuses)
  end

  def settled?(%__MODULE__{status: status}),
    do: status in ~w(waiting_for_input waiting_for_approval completed failed refused)

  defp fields do
    [
      :message_id,
      :caller_kind,
      :caller_id,
      :transport,
      :target_agent_id,
      :idempotency_key,
      :prompt_hash,
      :prompt,
      :provider_correlation_id,
      :continues_message_id,
      :status,
      :delivery,
      :provider,
      :agent_generation,
      :agent_turn_id,
      :arc_id,
      :provider_session_id,
      :detail,
      :result,
      :error,
      :started_at,
      :completed_at
    ]
  end
end
