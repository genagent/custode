defmodule Custode.RoleBinding do
  @moduledoc "A live Mission membership that lends one declarative RoleTemplate."

  use Ecto.Schema

  import Ecto.Changeset

  alias Custode.{Attempt, Mission}

  @authority_sources ~w(legacy_routine database)
  @lifecycles ~w(active retired)

  schema "role_bindings" do
    field(:binding_id, :string)
    field(:key, :string)
    field(:template_key, :string)
    field(:template_version, :string)
    field(:authority_source, :string)
    field(:legacy_routine_id, :string)
    field(:scoped_overrides, :map, default: %{})
    field(:grants, :map, default: %{})
    field(:lifecycle, :string, default: "active")
    field(:provenance, :map, default: %{})
    field(:retired_at, :utc_datetime_usec)
    belongs_to(:mission, Mission)
    has_many(:attempts, Attempt)
    timestamps(type: :utc_datetime_usec)
  end

  @type t :: %__MODULE__{}

  def create_changeset(attrs) do
    %__MODULE__{}
    |> cast(attrs, fields())
    |> validate_binding()
    |> unique_constraint(:binding_id)
    |> unique_constraint([:mission_id, :key])
    |> unique_constraint(:legacy_routine_id)
    |> foreign_key_constraint(:mission_id)
  end

  def legacy_projection_changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :template_key,
      :template_version,
      :scoped_overrides,
      :grants,
      :lifecycle,
      :provenance,
      :retired_at
    ])
    |> validate_binding()
  end

  def database_update_changeset(%__MODULE__{authority_source: "database"} = binding, attrs) do
    binding
    |> cast(attrs, [
      :template_key,
      :template_version,
      :scoped_overrides,
      :grants,
      :lifecycle,
      :provenance,
      :retired_at
    ])
    |> validate_binding()
  end

  defp fields do
    [
      :binding_id,
      :mission_id,
      :key,
      :template_key,
      :template_version,
      :authority_source,
      :legacy_routine_id,
      :scoped_overrides,
      :grants,
      :lifecycle,
      :provenance,
      :retired_at
    ]
  end

  defp validate_binding(changeset) do
    changeset
    |> validate_required([
      :binding_id,
      :mission_id,
      :key,
      :template_key,
      :template_version,
      :authority_source,
      :scoped_overrides,
      :grants,
      :lifecycle,
      :provenance
    ])
    |> validate_inclusion(:authority_source, @authority_sources)
    |> validate_inclusion(:lifecycle, @lifecycles)
    |> validate_authority()
  end

  defp validate_authority(changeset) do
    case {get_field(changeset, :authority_source), get_field(changeset, :legacy_routine_id)} do
      {"legacy_routine", id} when is_binary(id) and id != "" -> changeset
      {"legacy_routine", _missing} -> add_error(changeset, :legacy_routine_id, "is required")
      {"database", nil} -> changeset
      {"database", _id} -> add_error(changeset, :legacy_routine_id, "must be absent")
      _invalid -> changeset
    end
  end
end
