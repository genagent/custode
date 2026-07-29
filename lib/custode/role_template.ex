defmodule Custode.RoleTemplate do
  @moduledoc """
  Declarative, versioned capability and execution definition.

  RoleTemplates are compatibility projections over configuration. They are
  not database rows and never represent a provider process.
  """

  @enforce_keys [
    :key,
    :version,
    :role,
    :responsibility,
    :intent,
    :operation_grants,
    :transport_allowlists,
    :recipe,
    :prompt_assets,
    :executor_defaults,
    :budget_defaults,
    :limits,
    :provenance
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: String.t(),
          version: String.t(),
          role: String.t(),
          responsibility: String.t(),
          intent: map(),
          operation_grants: [String.t()],
          transport_allowlists: map(),
          recipe: map(),
          prompt_assets: [map()],
          executor_defaults: map(),
          budget_defaults: map(),
          limits: map(),
          provenance: map()
        }
end
