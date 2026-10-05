defmodule Custode.Repo.Migrations.RetainSubjectAssignments do
  use Ecto.Migration

  def change do
    create table(:subject_assignments, primary_key: false) do
      add(:assignment_id, :text, primary_key: true)
      add(:helper_id, :text, null: false)
      add(:root_id, :text, null: false)
      add(:fingerprint, :text, null: false)
      add(:status, :text, null: false)
      add(:record, :map, null: false)
      add(:expires_at, :utc_datetime_usec, null: false)
      add(:at, :utc_datetime_usec, null: false)
    end

    create(index(:subject_assignments, [:helper_id, :status]))

    create table(:subject_assignment_launches, primary_key: false) do
      add(:launch_id, :text, primary_key: true)
      add(:assignment_id, :text, null: false)
      add(:job_id, :bigint, null: false)
      add(:record, :map, null: false)
      add(:config_path, :text, null: false)
      add(:settled, :boolean, null: false, default: false)
      add(:at, :utc_datetime_usec, null: false)
    end

    create(unique_index(:subject_assignment_launches, [:assignment_id]))
    create(unique_index(:subject_assignment_launches, [:job_id]))
  end
end
