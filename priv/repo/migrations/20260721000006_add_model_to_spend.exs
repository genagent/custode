defmodule Custode.Repo.Migrations.AddModelToSpend do
  use Ecto.Migration

  def change do
    alter table(:spend) do
      add :model, :string
    end
  end
end
