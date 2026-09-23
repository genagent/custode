defmodule Custode.MCP.MCPEx.Adapter do
  @moduledoc false

  alias Anubis.MCP.Error, as: AnubisError
  alias Anubis.Server.{Frame, Response}
  alias Custode.MCP.{Server, WorkResources}
  alias MCP.Error

  @spec tool(String.t()) :: Anubis.Server.Component.Tool.t()
  def tool(name) do
    Enum.find(Server.__components__(:tool), &(&1.name == name)) ||
      raise ArgumentError, "unknown Custode MCP tool #{inspect(name)}"
  end

  @spec wire(term()) :: term()
  def wire(nil), do: nil
  def wire(value), do: value |> JSON.encode!() |> Jason.decode!()

  @spec call_tool(String.t(), map(), MCP.Context.t()) ::
          {:ok, MCP.Result.t()} | {:error, Error.t()}
  def call_tool(name, params, context) do
    component = tool(name)

    with {:ok, frame} <- frame(context),
         {:ok, arguments} <- validate(component, params) do
      case component.handler.execute(arguments, frame) do
        {:reply, response, _frame} ->
          {:ok, MCP.Result.raw(Response.to_protocol(response))}

        {:error, error, _frame} ->
          {:error, error(error)}

        {:noreply, _frame} ->
          {:error, Error.internal("Custode tool returned without a response")}
      end
    end
  end

  @spec read_resource(String.t(), String.t(), MCP.Context.t()) ::
          {:ok, MCP.Result.t()} | {:error, Error.t()}
  def read_resource(uri, mime_type, context) do
    with {:ok, frame} <- frame(context) do
      case WorkResources.read(uri, frame) do
        {:reply, response, _frame} ->
          content = Response.to_protocol(response, uri, mime_type)
          {:ok, MCP.Result.resource_read(content)}

        {:error, error, _frame} ->
          {:error, error(error)}
      end
    end
  end

  defp frame(%MCP.Context{auth: %{identity: identity, origin: origin}})
       when is_map(identity) and origin in [:cli, :mcp] do
    {:ok,
     Frame.new(%{
       custode_identity: identity,
       custode_transport: origin
     })}
  end

  defp frame(_context), do: {:error, Error.internal("Missing verified Custode identity")}

  defp validate(%{validate_input: nil}, params), do: {:ok, params}

  defp validate(%{validate_input: validate}, params) do
    case validate.(params) do
      {:ok, arguments} -> {:ok, arguments}
      {:error, reason} -> {:error, Error.invalid_params("Invalid params", wire(reason))}
    end
  end

  defp error(%AnubisError{} = error) do
    %Error{
      code: error.code,
      message: error.message || to_string(error.reason),
      data: wire(error.data),
      kind: error_kind(error.code)
    }
  end

  defp error(reason), do: Error.execution(reason)

  defp error_kind(code) when code in [-32_700, -32_600, -32_601, -32_602], do: :protocol
  defp error_kind(_code), do: :execution
end

defmodule Custode.MCP.MCPEx.Tools do
  @moduledoc false

  @names Custode.MCP.ToolPolicy.all() |> Map.keys() |> Enum.sort()

  @spec names() :: [String.t()]
  def names, do: @names

  @spec module(String.t()) :: module()
  def module(name) when name in @names,
    do: Module.concat(__MODULE__, Macro.camelize(name))
end

for name <- Custode.MCP.MCPEx.Tools.names() do
  module = Custode.MCP.MCPEx.Tools.module(name)

  contents =
    quote bind_quoted: [name: name] do
      @moduledoc false
      @behaviour MCP.Tool

      @name name

      @impl MCP.Tool
      def name, do: @name

      @impl MCP.Tool
      def description, do: Custode.MCP.MCPEx.Adapter.tool(@name).description

      @impl MCP.Tool
      def input_schema,
        do: @name |> Custode.MCP.MCPEx.Adapter.tool() |> Map.fetch!(:input_schema)

      @impl MCP.Tool
      def output_schema,
        do: @name |> Custode.MCP.MCPEx.Adapter.tool() |> Map.fetch!(:output_schema)

      @impl MCP.Tool
      def annotations do
        @name
        |> Custode.MCP.MCPEx.Adapter.tool()
        |> Map.fetch!(:annotations)
        |> Kernel.||(%{})
        |> Custode.MCP.MCPEx.Adapter.wire()
      end

      @impl MCP.Tool
      def call(params, context), do: Custode.MCP.MCPEx.Adapter.call_tool(@name, params, context)
    end

  Module.create(module, contents, Macro.Env.location(__ENV__))
end

defmodule Custode.MCP.MCPEx.Resources do
  @moduledoc false

  alias Custode.MCP.WorkResources

  @definitions Enum.map(WorkResources.resource_definitions(), &Map.put(&1, :kind, :resource)) ++
                 Enum.map(WorkResources.template_definitions(), &Map.put(&1, :kind, :template))

  @spec definitions() :: [map()]
  def definitions, do: @definitions

  @spec module(String.t()) :: module()
  def module(name), do: Module.concat(__MODULE__, Macro.camelize(name))

  @spec modules() :: [module()]
  def modules, do: Enum.map(@definitions, &module(&1.name))
end

for definition <- Custode.MCP.MCPEx.Resources.definitions() do
  module = Custode.MCP.MCPEx.Resources.module(definition.name)

  location =
    case definition.kind do
      :resource -> [uri: definition.uri]
      :template -> [uri_template: definition.uri]
    end

  opts =
    location ++
      [
        name: definition.name,
        title: definition.title,
        description: definition.description,
        mime_type: "application/json"
      ]

  contents =
    quote do
      @moduledoc false
      use MCP.Resource, unquote(Macro.escape(opts))

      @impl MCP.Resource
      def read(%{"uri" => uri}, context) do
        Custode.MCP.MCPEx.Adapter.read_resource(uri, "application/json", context)
      end
    end

  Module.create(module, contents, Macro.Env.location(__ENV__))
end
