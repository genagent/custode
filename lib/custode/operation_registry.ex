defmodule Custode.OperationRegistry do
  @moduledoc "Deterministic, immutable lookup for operation definitions."

  alias Custode.OperationDefinition
  alias Custode.Operations.Fleet.PauseAgent
  alias Custode.Operations.Missions
  alias Custode.Operations.RoleBindings

  @enforce_keys [:definitions]
  defstruct [:definitions]

  @type t :: %__MODULE__{definitions: %{String.t() => OperationDefinition.t()}}

  @spec new([OperationDefinition.t()]) :: {:ok, t()} | {:error, term()}
  def new(definitions) when is_list(definitions) do
    Enum.reduce_while(definitions, {:ok, %{}}, fn
      %OperationDefinition{name: name} = definition, {:ok, acc} ->
        if Map.has_key?(acc, name) do
          {:halt, {:error, {:duplicate_operation, name}}}
        else
          {:cont, {:ok, Map.put(acc, name, definition)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_definition}}
    end)
    |> case do
      {:ok, definitions_by_name} -> {:ok, %__MODULE__{definitions: definitions_by_name}}
      error -> error
    end
  end

  @spec default() :: t()
  def default do
    {:ok, registry} =
      new([
        PauseAgent.definition(),
        Missions.Archive.definition(),
        Missions.Create.definition(),
        Missions.ProjectLegacyRoutine.definition(),
        Missions.Update.definition(),
        RoleBindings.Create.definition(),
        RoleBindings.ProjectLegacyRoutine.definition(),
        RoleBindings.Update.definition()
      ])

    registry
  end

  @spec fetch(t(), String.t()) :: {:ok, OperationDefinition.t()} | :error
  def fetch(%__MODULE__{definitions: definitions}, name), do: Map.fetch(definitions, name)

  @spec list(t()) :: [OperationDefinition.t()]
  def list(%__MODULE__{definitions: definitions}) do
    definitions
    |> Map.values()
    |> Enum.sort_by(& &1.name)
  end
end
