defmodule Custode.Repo.Migrations.CreateNextBeats do
  use Ecto.Migration

  # An agent's one-shot request for when it should next run (#526). One row
  # per routine at most: a second request replaces the first.
  def change do
    create table(:next_beats, primary_key: false) do
      add(:routine_id, :string, primary_key: true)
      add(:at, :utc_datetime_usec, null: false)
      add(:reason, :text)
      add(:requested_minutes, :integer)
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end
  end
end
