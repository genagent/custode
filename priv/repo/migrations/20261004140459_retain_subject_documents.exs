defmodule Custode.Repo.Migrations.RetainSubjectDocuments do
  use Ecto.Migration
  def change do
    create table(:subject_root_bindings, primary_key: false) do
      add(:root_id, :string, primary_key: true)
      add(:binding, :map, null: false)
    end
    create table(:subject_document_operations, primary_key: false) do
      add(:request_id, :string, primary_key: true)
      add(:root_id, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:record, :map, null: false)
    end
    create index(:subject_document_operations, [:root_id])
  end
end
