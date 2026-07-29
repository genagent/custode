defmodule Custode.MissionTarget do
  @moduledoc "Typed external or conceptual target belonging to a Mission."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.Mission

  schema "mission_targets" do
    field(:kind, :string)
    field(:external_id, :string)
    field(:display_name, :string)
    field(:metadata, :map, default: %{})
    belongs_to(:mission, Mission)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def changeset(target \\ %__MODULE__{}, attrs) do
    target
    |> cast(attrs, [:mission_id, :kind, :external_id, :display_name, :metadata])
    |> validate_required([:mission_id, :kind, :external_id, :display_name])
    |> validate_format(:kind, ~r/^[a-z][a-z0-9_]*$/)
    |> validate_github_projection()
    |> unique_constraint([:mission_id, :kind, :external_id])
    |> foreign_key_constraint(:mission_id)
  end

  defp validate_github_projection(changeset) do
    case get_field(changeset, :kind) do
      "github_repository" ->
        validate_format(changeset, :display_name, ~r/^[^\/\s]+\/[^\/\s]+$/)

      _other ->
        changeset
    end
  end
end
