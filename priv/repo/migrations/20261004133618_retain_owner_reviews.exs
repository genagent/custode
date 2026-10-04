defmodule Custode.Repo.Migrations.RetainOwnerReviews do
  use Ecto.Migration
  def change do
    create table(:owner_reviews, primary_key: false) do
      add(:request_id, :string, primary_key: true)
      add(:owner_id, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:record, :map, null: false)
    end
    create index(:owner_reviews, [:owner_id])
  end
end
