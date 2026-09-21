defmodule Custode.Repo.Migrations.AddRepoToGates do
  use Ecto.Migration

  # The repository a gate acts on, when the raising turn named one (#542). A
  # reviewer has no repository of its own, so without this its gates never
  # got a risk. Nullable and not backfilled: NULL means the routine's own.
  def change do
    alter table(:gates) do
      add(:repo, :string)
    end
  end
end
