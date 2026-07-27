defmodule Custode.Repo.Migrations.AddDisownedPrs do
  use Ecto.Migration

  # "Not mine, do not touch" as a RECORD (#313).
  #
  # Agents already reach this judgment and already write it down, in the prose
  # of their self-curated panels. A resolver cannot read prose, so the fact was
  # recorded in a form nothing could act on: mdbook-lint's #400 sat in the
  # watching group on a red check its own panel had disowned.
  #
  # design/002's test: the machine queries it back -- on every attention
  # resolve, to decide whether a red check is the fleet's problem or the
  # operator's. A record, not a file.
  def change do
    create table(:disowned_prs) do
      add(:repo, :string, null: false)
      add(:number, :integer, null: false)
      # who disowned it, for the audit trail: a disownment is a judgment, and
      # judgments have authors
      add(:agent_id, :string, null: false)
      add(:reason, :text)
      timestamps(type: :utc_datetime_usec)
    end

    # One disownment per PR: a second agent reaching the same conclusion is
    # not new information, and reclaiming has to be unambiguous.
    create(unique_index(:disowned_prs, [:repo, :number]))
  end
end
