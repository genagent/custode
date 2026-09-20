defmodule Custode.Repo.Migrations.AddClassToGates do
  use Ecto.Migration

  # The class of action an approval gate asks for (#451), declared by the
  # agent when it raises the gate. Nullable and not backfilled: the rows that
  # exist carry free prose, and prose cannot be classified after the fact.
  def change do
    alter table(:gates) do
      add(:class, :string)
    end

    create(index(:gates, [:class]))
  end
end
