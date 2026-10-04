defmodule Custode.MCP.Tool do
  @moduledoc "Native Snodo callback adapter for Custode's shared tool operations."

  @callback execute(map(), Custode.MCP.CallContext.t()) ::
              {:reply, Snodo.Result.t(), Custode.MCP.CallContext.t()}

  defmacro __using__(opts) do
    quote do
      use Snodo.Tool, unquote(opts)
      alias Custode.MCP.{Arguments, Snodo.Adapter}
      @behaviour Custode.MCP.Tool
      description(@moduledoc)
      title(unquote(opts[:name]))
      @before_compile Custode.MCP.Tool

      @impl Snodo.Tool
      def call(params, context) do
        with {:ok, caller} <- Adapter.caller(context),
             {:ok, arguments} <-
               Arguments.validate(params, input_schema(), argument_keys()) do
          {:reply, result, _caller} = execute(arguments, caller)
          {:ok, result}
        end
      end
    end
  end

  defmacro __before_compile__(env) do
    keys = env.module |> Module.get_attribute(:mcp_tool_input_schema) |> argument_keys()

    quote do
      defp argument_keys, do: unquote(Macro.escape(keys))
    end
  end

  defp argument_keys(schema) do
    properties = Map.get(schema, "properties", %{})
    own = Map.new(properties, fn {key, _} -> {key, String.to_atom(key)} end)

    nested =
      Enum.reduce(properties, %{}, fn {_key, child}, acc ->
        Map.merge(acc, argument_keys(child))
      end)

    own |> Map.merge(nested) |> Map.merge(argument_keys_for_items(schema))
  end

  defp argument_keys_for_items(%{"items" => child}), do: argument_keys(child)
  defp argument_keys_for_items(_schema), do: %{}
end
