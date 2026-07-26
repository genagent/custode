defmodule Custode.Repo.Migrations.AddAsks do
  use Ecto.Migration

  # A non-blocking question to the operator (#299). Distinct from `gates`,
  # which record a BLOCKING hold: a gate parks the agent until the operator
  # decides, an ask leaves the turn finished and the agent beating.
  #
  # A record rather than a file (design/002): the machine queries it back --
  # open asks, their age, the attention ranking, closure -- rather than
  # someone merely reading it once.
  def change do
    create table(:asks) do
      add(:agent_id, :string, null: false)
      add(:question, :text, null: false)
      # what the agent was doing when it asked, for the operator's context
      add(:detail, :text)
      add(:answer, :text)
      add(:status, :string, null: false, default: "open")
      add(:answered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    # The hot query is "every open ask, oldest first" -- the attention
    # resolver runs it on every page render.
    create(index(:asks, [:status, :inserted_at]))
    create(index(:asks, [:agent_id]))
  end
end
