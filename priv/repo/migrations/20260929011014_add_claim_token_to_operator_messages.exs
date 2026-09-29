defmodule Custode.Repo.Migrations.AddClaimTokenToOperatorMessages do
  use Ecto.Migration

  def change do
    alter table(:operator_messages) do
      add(:claim_token, :string)
      add(:claimed_at, :utc_datetime_usec)
      add(:claim_after_job_id, :bigint)
    end
  end
end
