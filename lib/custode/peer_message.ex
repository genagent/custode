defmodule Custode.PeerMessage do
  @moduledoc "A durable request, FYI or reply between authenticated routines."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, Ecto.UUID, autogenerate: true}
  @fields [
    :id,
    :sender,
    :recipient,
    :kind,
    :subject,
    :body,
    :idempotency_key,
    :reply_to,
    :correlation_id,
    :depth,
    :delivery_state,
    :error,
    :delivered_at,
    :acknowledged_at,
    :inserted_at,
    :updated_at
  ]

  schema "peer_messages" do
    field(:sender, :string)
    field(:recipient, :string)
    field(:kind, :string)
    field(:subject, :string)
    field(:body, :string)
    field(:idempotency_key, :string)
    field(:reply_to, Ecto.UUID)
    field(:correlation_id, Ecto.UUID)
    field(:depth, :integer, default: 0)
    field(:delivery_state, :string, default: "pending")
    field(:error, :string)
    field(:delivered_at, :utc_datetime_usec)
    field(:acknowledged_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @doc false
  def changeset(message, attrs) do
    message
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required([
      :sender,
      :recipient,
      :kind,
      :subject,
      :body,
      :idempotency_key,
      :correlation_id,
      :depth,
      :delivery_state
    ])
    |> validate_inclusion(:kind, ~w(request fyi reply))
    |> validate_inclusion(:delivery_state, ~w(pending delivered failed))
    |> validate_number(:depth, greater_than_or_equal_to: 0)
    |> unique_constraint([:sender, :idempotency_key])
  end

  @doc false
  def delivery_changeset(message, attrs) do
    message
    |> cast(attrs, [:delivery_state, :error, :delivered_at])
    |> validate_inclusion(:delivery_state, ~w(pending delivered failed))
  end
end
