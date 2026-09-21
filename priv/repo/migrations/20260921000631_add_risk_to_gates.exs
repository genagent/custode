defmodule Custode.Repo.Migrations.AddRiskToGates do
  use Ecto.Migration

  # The risk of the paths a gated pull request changes (#451), the second axis
  # beside the class. All nullable and not backfilled: NULL means nobody
  # looked, which is not the same as low.
  def change do
    alter table(:gates) do
      add(:pr_number, :integer)
      add(:risk, :string)
      add(:risk_paths, :text)
    end
  end
end
