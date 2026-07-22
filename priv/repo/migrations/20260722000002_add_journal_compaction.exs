defmodule Custode.Repo.Migrations.AddJournalCompaction do
  use Ecto.Migration

  # Semantic compaction (#214): a journal entry the agent has distilled into
  # a summary carries a compacted_at stamp. NULL means live (the agent's
  # long-term self, never age-deleted); non-NULL means the agent already
  # folded it into a summary, so the janitor may retire it once it also ages
  # out -- the two-phase rule (distilled AND old), never blind deletion.
  def change do
    alter table(:journal_entries) do
      add(:compacted_at, :utc_datetime_usec)
    end

    create(index(:journal_entries, [:routine_id, :compacted_at]))
  end
end
