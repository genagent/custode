defmodule Custode.LegacyRoutineMissionMapping do
  @moduledoc "One-way, durable compatibility mapping from a legacy routine to Mission scope."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.Mission

  @strategies ~w(repository fixed_mission repository_attempts ephemeral_per_investigation)
  @statuses ~w(active exception)
  @mission_strategies ~w(repository fixed_mission)

  schema "legacy_routine_mission_mappings" do
    field(:mapping_id, :string)
    field(:legacy_routine_id, :string)
    field(:strategy, :string)
    field(:mapping_identity, :string)
    field(:status, :string, default: "active")
    field(:source_snapshot, :map)
    field(:last_observed_snapshot, :map)
    field(:last_observed_fingerprint, :string)
    field(:exception, :map)
    belongs_to(:mission, Mission)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, [
      :mapping_id,
      :legacy_routine_id,
      :mission_id,
      :strategy,
      :mapping_identity,
      :status,
      :source_snapshot,
      :last_observed_snapshot,
      :last_observed_fingerprint,
      :exception
    ])
    |> validate_mapping()
    |> unique_constraint(:mapping_id)
    |> unique_constraint(:legacy_routine_id)
    |> foreign_key_constraint(:mission_id)
  end

  def observe_changeset(mapping, attrs) do
    mapping
    |> cast(attrs, [
      :status,
      :last_observed_snapshot,
      :last_observed_fingerprint,
      :exception
    ])
    |> validate_mapping()
  end

  defp validate_mapping(changeset) do
    changeset
    |> validate_required([
      :mapping_id,
      :legacy_routine_id,
      :strategy,
      :mapping_identity,
      :status,
      :source_snapshot,
      :last_observed_snapshot,
      :last_observed_fingerprint
    ])
    |> validate_inclusion(:strategy, @strategies)
    |> validate_inclusion(:status, @statuses)
    |> validate_mission()
  end

  defp validate_mission(changeset) do
    strategy = get_field(changeset, :strategy)
    mission_id = get_field(changeset, :mission_id)

    cond do
      strategy in @mission_strategies and is_nil(mission_id) ->
        add_error(changeset, :mission_id, "is required for this strategy")

      strategy not in @mission_strategies and not is_nil(mission_id) ->
        add_error(changeset, :mission_id, "must be absent for this strategy")

      true ->
        changeset
    end
  end
end
