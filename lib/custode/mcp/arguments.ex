defmodule Custode.MCP.Arguments do
  @moduledoc """
  Validates native JSON Schemas and projects declared fields into domain arguments.
  Optional nulls are omitted, as with the original tool contracts. Only schema
  property names become atoms; caller-supplied unknown keys are discarded.
  """
  alias Snodo.Schema.Validator.Basic

  @spec validate(map(), map(), map()) :: {:ok, map()} | {:error, Snodo.Error.t()}
  def validate(params, schema, keys) do
    normalized = project(params, schema, :strings, keys)

    case Basic.validate(normalized, schema) do
      :ok ->
        {:ok, project(normalized, schema, :atoms, keys)}

      {:error, error} ->
        {:error,
         Snodo.Error.invalid_params("Invalid params", %{
           "path" => error.path,
           "keyword" => error.keyword,
           "message" => error.message
         })}
    end
  end

  defp project(value, %{"properties" => properties} = schema, mode, keys) when is_map(value) do
    required = Map.get(schema, "required", [])

    for {key, child} <- properties,
        {:ok, entry} <- [Map.fetch(value, key)],
        not is_nil(entry) or key in required,
        into: %{} do
      name = if mode == :atoms, do: Map.fetch!(keys, key), else: key
      {name, project(entry, child, mode, keys)}
    end
  end

  defp project(value, %{"items" => child}, mode, keys) when is_list(value),
    do: Enum.map(value, &project(&1, child, mode, keys))

  defp project(value, _schema, _mode, _keys), do: value
end
