defmodule Custode.InboxWake do
  @moduledoc "A durable, coalesced request to wake one routine for inbox activity."

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:routine_id, :string, autogenerate: false}
  schema "inbox_wakes" do
    field(:wake_id, Ecto.UUID)
    field(:state, :string, default: "pending")
    field(:reason, :string, default: "inbox_activity")
    field(:note_count, :integer, default: 1)
    field(:first_note_at, :utc_datetime_usec)
    field(:last_note_at, :utc_datetime_usec)
    field(:due_at, :utc_datetime_usec)
    field(:blocked_by, :string)
    field(:spend_override, :boolean, default: false)
    field(:retry_count, :integer, default: 0)
    field(:claim_token, Ecto.UUID)
    field(:claimed_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  @fields [
    :routine_id,
    :wake_id,
    :state,
    :reason,
    :note_count,
    :first_note_at,
    :last_note_at,
    :due_at,
    :blocked_by,
    :spend_override,
    :retry_count,
    :claim_token,
    :claimed_at
  ]

  @doc false
  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, @fields)
    |> validate_required([
      :routine_id,
      :wake_id,
      :state,
      :reason,
      :note_count,
      :first_note_at,
      :last_note_at,
      :due_at
    ])
    |> validate_inclusion(:state, ~w(pending dispatching))
    |> validate_number(:note_count, greater_than: 0)
    |> unique_constraint(:wake_id)
  end

  @doc false
  def update_changeset(wake, attrs) do
    wake
    |> cast(attrs, @fields -- [:routine_id, :wake_id])
    |> validate_inclusion(:state, ~w(pending dispatching))
    |> validate_number(:note_count, greater_than: 0)
  end
end
