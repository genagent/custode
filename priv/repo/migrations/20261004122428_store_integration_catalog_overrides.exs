defmodule Custode.Repo.Migrations.StoreIntegrationCatalogOverrides do
  use Ecto.Migration

  def change do
    create table(:integration_overrides, primary_key: false) do
      add :name, :string, primary_key: true
      add :settings, :map, null: false
    end

    create table(:integration_requests, primary_key: false) do
      add :request_id, :string, primary_key: true
      add :fingerprint, :string, null: false
      add :result, :map, null: false
    end
  end
end
