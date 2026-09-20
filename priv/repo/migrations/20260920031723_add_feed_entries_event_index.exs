defmodule Custode.Repo.Migrations.AddFeedEntriesEventIndex do
  use Ecto.Migration

  # `Custode.Feed.recent_by_event/2` filters on `event` and orders by `id`,
  # and attention resolves workflow proposals and parked runs through it --
  # so it runs under every page render and every PubSub refresh (#480).
  # Without this index that is a full scan of a table which grows by a few
  # thousand rows a day from sensors alone.
  #
  # `(agent, id)` already covers `for_agent/2` and `mark_gate_resolved/2`;
  # it was created with the table in 20260721000004.
  def change do
    create index(:feed_entries, [:event, :id])
  end
end
