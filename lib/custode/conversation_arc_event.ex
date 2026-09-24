defmodule Custode.ConversationArcEvent do
  @moduledoc "Append-only decision and outcome history for a conversation arc."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.ConversationArc

  schema "conversation_arc_events" do
    belongs_to(:conversation_arc, ConversationArc)
    field(:kind, :string)
    field(:decision, :string)
    field(:reason, :string)
    field(:outcome, :string)
    field(:provider_session_id, :string)
    field(:details, :map, default: %{})
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @type t :: %__MODULE__{}

  def changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :conversation_arc_id,
      :kind,
      :decision,
      :reason,
      :outcome,
      :provider_session_id,
      :details
    ])
    |> validate_required([:conversation_arc_id, :kind, :details])
    |> foreign_key_constraint(:conversation_arc_id)
  end
end
