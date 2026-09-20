defmodule Custode.Repo.Migrations.AddContinuationEndedAtToGates do
  use Ecto.Migration

  # When an approved gate's continuation ended (#451). An approval is a live
  # grant from the decision until the agent next leaves `:running`; NULL on an
  # approved row means "still running". Every row that exists predates the
  # column and its turn is long over, so each is closed at its own updated_at:
  # without that, every old approval would read as a live grant.
  def up do
    alter table(:gates) do
      add(:continuation_ended_at, :utc_datetime_usec)
    end

    execute("UPDATE gates SET continuation_ended_at = updated_at WHERE outcome = 'approved'")
  end

  def down do
    alter table(:gates) do
      remove(:continuation_ended_at)
    end
  end
end
