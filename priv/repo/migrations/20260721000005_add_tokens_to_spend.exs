defmodule Custode.Repo.Migrations.AddTokensToSpend do
  use Ecto.Migration

  def change do
    alter table(:spend) do
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cache_creation_tokens, :integer
      add :cache_read_tokens, :integer
      add :stop_reason, :string
    end
  end
end
