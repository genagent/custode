defmodule Custode.Repo.Migrations.CreateGateReviews do
  use Ecto.Migration

  def change do
    create table(:gate_reviews) do
      add(:repo, :string, null: false)
      add(:pr_number, :integer, null: false)
      add(:head_sha, :string, null: false)
      add(:author_provider, :string, null: false)
      add(:reviewer_provider, :string, null: false)
      add(:round, :integer, null: false)
      add(:status, :string, null: false, default: "pending")
      add(:evidence_digest, :string)
      add(:summary, :text)
      add(:findings, :text)
      add(:error, :text)
      add(:completed_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:gate_reviews, [:repo, :pr_number, :head_sha]))
    create(index(:gate_reviews, [:repo, :pr_number, :round]))

    alter table(:gates) do
      add(:review_id, references(:gate_reviews, on_delete: :nothing))
      add(:review_state, :string)
    end

    create(index(:gates, [:review_id]))
  end
end
