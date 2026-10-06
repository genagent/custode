defmodule Custode.Repo.Migrations.RetainWorkAgreements do
  use Ecto.Migration

  def change do
    create table(:work_agreements) do
      add(:agreement_id, :string, null: false)
      add(:routine_id, :string, null: false)
      add(:current_revision, :integer, null: false, default: 1)
      add(:last_sequence, :integer, null: false, default: 0)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:work_agreements, [:agreement_id]))
    create(index(:work_agreements, [:routine_id, :id]))

    create table(:work_agreement_records) do
      add(:record_id, :string, null: false)

      add(
        :agreement_id,
        references(:work_agreements, column: :agreement_id, type: :string, on_delete: :restrict),
        null: false
      )

      add(:revision, :integer, null: false)
      add(:sequence, :integer, null: false)
      add(:kind, :string, null: false)
      add(:actor_kind, :string, null: false)
      add(:actor_id, :string, null: false)
      add(:actor_revision, :string)
      add(:request_id, :string, null: false)
      add(:fingerprint, :string, null: false)
      add(:payload, :map, null: false)
      add(:submission_id, :string)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create(unique_index(:work_agreement_records, [:record_id]))
    create(unique_index(:work_agreement_records, [:agreement_id, :sequence]))
    create(unique_index(:work_agreement_records, [:actor_kind, :actor_id, :request_id]))
    create(unique_index(:work_agreement_records, [:submission_id]))
    create(index(:work_agreement_records, [:agreement_id, :revision, :kind]))
  end
end
