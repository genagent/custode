defmodule Custode.Repo.Migrations.RetainReturnContext do
  use Ecto.Migration
  def change do
    create table(:context_receipts, primary_key: false) do
      add :receipt_id, :string, primary_key: true
      add :actor_key, :string, null: false
      add :root_id, :string, null: false
      add :path, :string, null: false
      add :record, :map, null: false
      add :payload, :text
      add :at, :utc_datetime_usec, null: false
    end
    create index(:context_receipts, [:actor_key, :at])
    create table(:document_feedback, primary_key: false) do
      add :request_id, :string, primary_key: true
      add :root_id, :string, null: false
      add :path, :string, null: false
      add :fingerprint, :string, null: false
      add :record, :map, null: false
    end
  end
end
