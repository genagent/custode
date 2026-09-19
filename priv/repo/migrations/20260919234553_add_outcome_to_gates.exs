defmodule Custode.Repo.Migrations.AddOutcomeToGates do
  use Ecto.Migration

  # #448. A gate row stored `resolved` for an approval and a rejection alike.
  # The outcome was only ever written into the JSON of the feed entry beside
  # it (`Custode.Feed.mark_gate_resolved/2`), which nothing can query by.
  def up do
    alter table(:gates) do
      add(:outcome, :string)
      add(:decided_by, :string)
      add(:decided_via, :string)
      add(:reason, :text)
    end

    flush()

    # Backfill from that feed entry. The gate row and its feed entry are both
    # written from the same transition telemetry event, so they land within
    # milliseconds of each other; 120s is slack, and the ORDER BY keeps the
    # nearest one when an agent raised two gates inside it.
    execute("""
    UPDATE gates SET outcome = (
      SELECT json_extract(f.entry, '$.resolved')
      FROM feed_entries f
      WHERE f.agent = gates.agent_id
        AND f.event IN ('needs_approval', 'needs_input')
        AND json_extract(f.entry, '$.resolved') IS NOT NULL
        AND abs(strftime('%s', f.at) - strftime('%s', gates.inserted_at)) <= 120
      ORDER BY abs(strftime('%s', f.at) - strftime('%s', gates.inserted_at))
      LIMIT 1
    )
    WHERE status = 'resolved' AND outcome IS NULL
    """)
  end

  def down do
    alter table(:gates) do
      remove(:outcome)
      remove(:decided_by)
      remove(:decided_via)
      remove(:reason)
    end
  end
end
