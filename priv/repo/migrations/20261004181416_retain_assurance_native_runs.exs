defmodule Custode.Repo.Migrations.RetainAssuranceNativeRuns do
  use Ecto.Migration

  def change do
    create table(:assurance_native_runs, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:case_id, :string, null: false)
      add(:workspace, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:status, :string, null: false)
      add(:record, :map, null: false)
    end

    create(index(:assurance_native_runs, [:case_id]))
    create(unique_index(:assurance_native_runs, [:workspace]))
  end
end
