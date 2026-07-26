defmodule Custode.Repo.Migrations.AddIssueDrafts do
  use Ecto.Migration

  # The batch filing gate (#241, design/006 slice 1). A steward sweep drafts
  # several issues and raises ONE gate covering them; the operator drops the
  # entries it does not want while that gate is open, and the approved
  # continuation files what is left. The drafts live here because the gate
  # itself carries only a description string -- there is nowhere in the gate
  # for a per-entry decision to land.
  #
  # `labels` is a JSON array as text: ecto_sqlite3 has no array column, and a
  # comma-joined string would corrupt a label that contains a comma.
  def change do
    create table(:issue_drafts) do
      add(:batch_id, :string, null: false)
      add(:routine_id, :string, null: false)
      add(:repo, :string, null: false)
      add(:title, :string, null: false)
      add(:body, :text)
      add(:labels, :text)
      # "drafted" | "dropped" | "filed" | "failed"
      add(:status, :string, null: false, default: "drafted")
      add(:issue_url, :string)
      # the refusal that came back when a filing failed
      add(:note, :text)
      timestamps(type: :utc_datetime_usec)
    end

    create(index(:issue_drafts, [:batch_id]))
    create(index(:issue_drafts, [:routine_id, :status]))
  end
end
