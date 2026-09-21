defmodule Custode.MCP.NumericSchema do
  @moduledoc """
  JSON numbers accept integers and floats, while Peri needs an explicit
  `{:either, {:integer, :float}}` union. Its JSON Schema encoder emits
  `oneOf(integer, number)`, whose overlapping branches reject integers.

  Opted-in tools keep the union for validation and advertise a plain number
  for that exact, unconstrained union. Other field schemas stay unchanged.
  """

  defmacro __using__(_opts) do
    quote do
      alias Custode.MCP.NumericSchema

      defoverridable input_schema: 0

      @impl true
      def input_schema do
        NumericSchema.normalize(super())
      end
    end
  end

  @number_union [%{"type" => "integer"}, %{"type" => "number"}]

  @doc false
  def normalize(%{"properties" => properties} = schema) do
    Map.put(schema, "properties", Map.new(properties, &normalize_property/1))
  end

  defp normalize_property({name, %{"oneOf" => alternatives} = property})
       when alternatives == @number_union do
    {name, property |> Map.delete("oneOf") |> Map.put("type", "number")}
  end

  defp normalize_property(property), do: property
end
