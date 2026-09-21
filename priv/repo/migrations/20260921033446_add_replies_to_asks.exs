defmodule Custode.Repo.Migrations.AddRepliesToAsks do
  use Ecto.Migration

  # Up to three short answers the agent would accept (#450), as a JSON array.
  # Nullable: an ask with none is answered by typing, as every ask was.
  def change do
    alter table(:asks) do
      add(:replies, :text)
    end
  end
end
