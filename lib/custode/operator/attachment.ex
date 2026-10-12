defmodule Custode.Operator.Attachment do
  @moduledoc "Server-owned operator image metadata. Expired references remain as tombstones."

  use Ecto.Schema

  import Ecto.Changeset

  schema "operator_attachments" do
    field(:attachment_id, :string)
    field(:owner_id, :string)
    field(:agent_id, :string)
    field(:workspace, :string)
    field(:path, :string)
    field(:sha256, :string)
    field(:media_type, :string)
    field(:byte_count, :integer)
    field(:deleted_at, :utc_datetime_usec)
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(attrs) do
    fields = ~w(attachment_id owner_id agent_id workspace path sha256 media_type byte_count)a

    %__MODULE__{}
    |> cast(attrs, fields)
    |> validate_required(fields)
    |> unique_constraint(:attachment_id)
    |> unique_constraint([:owner_id, :agent_id, :workspace, :sha256],
      name: :operator_attachments_live_content_index
    )
  end
end
