defmodule Custode.Repo.Migrations.RetainAssuranceRecords do
  use Ecto.Migration

  def change do
    create table(:assurance_records, primary_key: false) do
      add(:id, :string, primary_key: true)
      add(:case_id, :string, null: false)
      add(:kind, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:record, :map, null: false)
    end

    create(index(:assurance_records, [:case_id, :kind]))
  end
end
