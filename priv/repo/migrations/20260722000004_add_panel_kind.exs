defmodule Custode.Repo.Migrations.AddPanelKind do
  use Ecto.Migration

  # Compatibility tombstone for parked commit 5a41a5f (#355).
  #
  # Some databases applied this migration while the panel-v2 branch was
  # parked, so its version and column exist there even though the feature
  # never shipped. Keep the historical migration verbatim so its recorded
  # version is explained. A later timestamped migration removes the unused
  # column, making fresh and previously affected databases converge on the
  # v1 panel schema without rewriting migration history.
  def change do
    alter table(:agent_panels) do
      add(:kind, :string, null: false, default: "html")
    end
  end
end
