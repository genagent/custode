defmodule Custode.Repo.Migrations.RecordRoutePreviewDecisions do
  use Ecto.Migration
  def change do
    create table(:route_decisions, primary_key: false) do
      add(:request_id, :string, primary_key: true)
      add(:fingerprint, :string, null: false)
      add(:actor_id, :string, null: false)
      add(:decision, :map, null: false)
    end
  end
end
