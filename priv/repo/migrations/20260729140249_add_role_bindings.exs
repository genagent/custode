defmodule Custode.Repo.Migrations.AddRoleBindings do
  use Ecto.Migration

  def change do
    create table(:role_bindings) do
      add(:binding_id, :string, null: false)
      add(:mission_id, references(:missions, on_delete: :restrict), null: false)
      add(:key, :string, null: false)
      add(:template_key, :string, null: false)
      add(:template_version, :string, null: false)
      add(:authority_source, :string, null: false)
      add(:legacy_routine_id, :string)
      add(:scoped_overrides, :map, null: false, default: %{})
      add(:grants, :map, null: false, default: %{})
      add(:lifecycle, :string, null: false, default: "active")
      add(:provenance, :map, null: false, default: %{})
      add(:retired_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:role_bindings, [:binding_id]))
    create(unique_index(:role_bindings, [:mission_id, :key]))
    create(unique_index(:role_bindings, [:legacy_routine_id]))
    create(index(:role_bindings, [:mission_id, :lifecycle]))
    create(index(:role_bindings, [:template_key, :template_version]))
  end
end
