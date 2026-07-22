defmodule Custode.Repo.Migrations.AddInstanceHeartbeat do
  use Ecto.Migration

  # The single-instance guard (#77): one singleton row carries the live
  # instance's identity and a heartbeat refreshed every few seconds. A boot
  # that finds a FRESH heartbeat it does not own refuses to start, so an
  # overlapping server during a graceful restart cannot double-run Oban jobs.
  def change do
    create table(:instance, primary_key: false) do
      add :key, :string, primary_key: true
      add :node, :string, null: false
      add :os_pid, :string, null: false
      add :beat_at, :utc_datetime_usec, null: false
    end
  end
end
