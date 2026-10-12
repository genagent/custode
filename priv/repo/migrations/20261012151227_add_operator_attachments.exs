defmodule Custode.Repo.Migrations.AddOperatorAttachments do
  use Ecto.Migration

  def change do
    create table(:operator_attachments) do
      add(:attachment_id, :string, null: false)
      add(:owner_id, :string, null: false)
      add(:agent_id, :string, null: false)
      add(:workspace, :string, null: false)
      add(:path, :string, null: false)
      add(:sha256, :string, null: false)
      add(:media_type, :string, null: false)
      add(:byte_count, :integer, null: false)
      add(:deleted_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:operator_attachments, [:attachment_id]))

    create(
      unique_index(:operator_attachments, [:owner_id, :agent_id, :workspace, :sha256],
        name: :operator_attachments_live_content_index,
        where: "deleted_at IS NULL"
      )
    )

    alter table(:operator_messages) do
      add(:attachment_id, :string)
    end

    create(index(:operator_messages, [:attachment_id]))
  end
end
