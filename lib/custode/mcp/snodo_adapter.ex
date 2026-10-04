defmodule Custode.MCP.Snodo.Adapter do
  @moduledoc false

  alias Custode.MCP.{CallContext, WorkResources}
  alias Snodo.{Error, Result}

  @spec caller(Snodo.Context.t()) :: {:ok, CallContext.t()} | {:error, Error.t()}
  def caller(%Snodo.Context{auth: %{identity: identity, origin: origin}})
      when is_map(identity) and origin in [:cli, :mcp] do
    {:ok, %CallContext{assigns: %{custode_identity: identity, custode_transport: origin}}}
  end

  def caller(_context), do: {:error, Error.internal("Missing verified Custode identity")}

  @spec read_resource(String.t(), String.t(), Snodo.Context.t()) ::
          {:ok, Result.t()} | {:error, Error.t()}
  def read_resource(uri, mime_type, context) do
    with {:ok, caller} <- caller(context) do
      case WorkResources.read(uri, caller) do
        {:reply, %Result{kind: :text, value: text}, _caller} ->
          {:ok, Result.resource_read([%{"uri" => uri, "mimeType" => mime_type, "text" => text}])}

        {:error, error, _caller} ->
          {:error, error}
      end
    end
  end
end

defmodule Custode.MCP.Snodo.Resources do
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

for definition <- Custode.MCP.Snodo.Resources.definitions() do
  module = Custode.MCP.Snodo.Resources.module(definition.name)

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
      use Snodo.Resource, unquote(Macro.escape(opts))

      @impl Snodo.Resource
      def read(%{"uri" => uri}, context) do
        Custode.MCP.Snodo.Adapter.read_resource(uri, "application/json", context)
      end
    end

  Module.create(module, contents, Macro.Env.location(__ENV__))
end
