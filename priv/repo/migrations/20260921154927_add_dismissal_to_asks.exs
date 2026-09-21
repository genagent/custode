defmodule Custode.Repo.Migrations.AddDismissalToAsks do
  use Ecto.Migration

  def change do
    alter table(:asks) do
      add :dismissal_reason, :text
      add :dismissed_at, :utc_datetime_usec
    end
  end
end
