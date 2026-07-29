defmodule Custode.Repo.Migrations.RemoveParkedPanelKind do
  use Ecto.Migration

  # Panel v2 never shipped, but parked commit 5a41a5f's preceding migration
  # reached at least one live database. Removing the unused compatibility
  # column makes that database and a fresh install converge on the v1 schema.
  # SQLite rebuilds the table for this alteration and preserves every v1 row.
  def change do
    alter table(:agent_panels) do
      remove(:kind, :string, null: false, default: "html")
    end
  end
end
