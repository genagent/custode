defmodule Custode.Test.CatalogProof do
  @moduledoc false
  alias Snodo.{Router, Server.Runtime, Subscription.Event}

  defmodule ReadV1 do
    @moduledoc false
    use Snodo.Tool, name: "fixture_read_v1", description: "Controlled read v1"
    def call(_arguments, context), do: {:ok, Snodo.Result.text(inspect(context.auth))}
  end

  defmodule ReadV2 do
    @moduledoc false
    use Snodo.Tool, name: "fixture_read_v2", description: "Controlled read v2"
    def call(_arguments, context), do: {:ok, Snodo.Result.text(inspect(context.auth))}
  end

  defmodule PromptV1 do
    @moduledoc false
    use Snodo.Prompt, name: "fixture_prompt_v1", arguments: []

    def render(_arguments, context),
      do:
        {:ok,
         Snodo.Result.prompt_get([
           Snodo.Prompt.message(:user, Snodo.Prompt.text(inspect(context.auth)))
         ])}
  end

  defmodule PromptV2 do
    @moduledoc false
    use Snodo.Prompt, name: "fixture_prompt_v2", arguments: []

    def render(_arguments, context),
      do:
        {:ok,
         Snodo.Result.prompt_get([
           Snodo.Prompt.message(:user, Snodo.Prompt.text(inspect(context.auth)))
         ])}
  end

  defmodule ResourceV1 do
    @moduledoc false
    use Snodo.Resource, name: "fixture_resource_v1", uri: "fixture://v1/context"

    def read(_params, context),
      do:
        {:ok,
         Snodo.Result.resource_read([
           %{"uri" => "fixture://v1/context", "text" => inspect(context.auth)}
         ])}
  end

  defmodule ResourceV2 do
    @moduledoc false
    use Snodo.Resource, name: "fixture_resource_v2", uri: "fixture://v2/context"

    def read(_params, context),
      do:
        {:ok,
         Snodo.Result.resource_read([
           %{"uri" => "fixture://v2/context", "text" => inspect(context.auth)}
         ])}
  end

  defmodule Policy do
    @moduledoc false
    @behaviour Snodo.Authorization
    def authorize(_phase, _component, context, state) do
      if context.auth == :fixture_owner and Agent.get(state, & &1.allowed),
        do: :ok,
        else: {:error, Snodo.Error.authorization(-32_003, "Fixture caller denied")}
    end
  end

  defmodule Source do
    @moduledoc false
    @behaviour Snodo.Subscription.Source
    def open(filter, context, state) do
      if context.auth == :fixture_owner and Agent.get(state, & &1.allowed) do
        {:ok, handle} = Agent.start(fn -> :queue.new() end)
        Agent.update(state, &Map.update!(&1, :streams, fn streams -> [handle | streams] end))
        {:ok, filter, handle}
      else
        {:error, Snodo.Error.authorization(-32_003, "Fixture subscription denied")}
      end
    end

    def next(handle, state) do
      if Agent.get(state, & &1.allowed), do: pull(handle, state), else: :closed
    end

    defp pull(handle, state) do
      case Agent.get_and_update(handle, &pop/1) do
        :pending ->
          Process.sleep(10)
          next(handle, state)

        result ->
          result
      end
    catch
      :exit, _reason -> :closed
    end

    defp pop(queue) do
      case :queue.out(queue) do
        {{:value, event}, rest} -> {{:ok, event}, rest}
        {:empty, _queue} -> {:pending, queue}
      end
    end

    def close(handle, _reason, state) do
      Agent.update(
        state,
        &Map.update!(&1, :streams, fn streams -> List.delete(streams, handle) end)
      )

      if Process.alive?(handle), do: Agent.stop(handle)
      :ok
    end
  end

  defmodule Observe do
    @moduledoc false
    @behaviour Snodo.Instrumentation
    def handle_event([:snodo, :server, :dispatch, :stop], _measurements, metadata, state) do
      Agent.update(
        state,
        &Map.update!(&1, :observations, fn observations ->
          [Map.take(metadata, [:method, :protocol_version, :outcome]) | observations]
        end)
      )
    end

    def handle_event(_event, _measurements, _metadata, _state), do: :ok
  end

  defmodule Endpoint do
    @moduledoc false
    @behaviour Plug
    alias Custode.Test.CatalogProof
    alias Snodo.Transport.Plug, as: MCPPlug
    def init(options), do: options

    def call(conn, options) do
      state = Keyword.fetch!(options, :state)

      versions = Plug.Conn.get_req_header(conn, "mcp-protocol-version")

      Agent.update(
        state,
        &Map.update!(&1, :http_versions, fn previous -> Enum.uniq(previous ++ versions) end)
      )

      auth =
        if Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fixture-owner"],
          do: :fixture_owner,
          else: :fixture_other

      control(conn, state, auth, options)
    end

    defp control(%{request_path: path} = conn, state, :fixture_owner, _options)
         when path in ["/control/catalog/1", "/control/catalog/2"] do
      revision = if path == "/control/catalog/1", do: 1, else: 2
      CatalogProof.publish(state, revision)
      Plug.Conn.send_resp(conn, 200, "published fixture revision")
    end

    defp control(conn, state, auth, options) do
      runtime = Agent.get(state, & &1.runtime)

      plug =
        MCPPlug.init(
          runtime: runtime,
          executor: Keyword.fetch!(options, :executor),
          path: "/mcp",
          request_timeout: 5_000,
          subscription_keepalive_ms: 100
        )

      conn |> Plug.Conn.assign(:mcp_auth, auth) |> MCPPlug.call(plug)
    end
  end

  def state,
    do: %{
      allowed: true,
      notifications: false,
      runtime: nil,
      streams: [],
      observations: [],
      http_versions: []
    }

  def publish(state, revision) when revision in [1, 2] do
    runtime = runtime(state, revision)

    streams =
      Agent.get_and_update(state, fn previous ->
        {previous.streams, %{previous | runtime: runtime}}
      end)

    events = [
      Event.tools_list_changed(),
      Event.prompts_list_changed(),
      Event.resources_list_changed()
    ]

    for handle <- streams, event <- events, do: Agent.update(handle, &:queue.in(event, &1))
    runtime
  end

  defp protocols(state) do
    if Agent.get(state, & &1.notifications),
      do: [Snodo.Protocol.V2026_07_28],
      else: [Snodo.Protocol.V2026_07_28, Snodo.Protocol.V2025_11_25, Snodo.Protocol.V2025_06_18]
  end

  defp capabilities(state) do
    entry = if Agent.get(state, & &1.notifications), do: %{"listChanged" => true}, else: %{}
    %{"tools" => entry, "prompts" => entry, "resources" => entry}
  end

  def runtime(state, revision) do
    {tool, prompt, resource} =
      if revision == 1, do: {ReadV1, PromptV1, ResourceV1}, else: {ReadV2, PromptV2, ResourceV2}

    router =
      Router.new()
      |> Router.register_tool(tool)
      |> Router.register_prompt(prompt)
      |> Router.register_resource(resource)

    Runtime.new(
      router: router,
      protocols: protocols(state),
      server_info: %{
        "name" => "controlled-catalog-proof",
        "version" => Integer.to_string(revision)
      },
      capabilities: capabilities(state),
      authorization: {Policy, state},
      subscription_source: {Source, state},
      instrumentation: {Observe, state}
    )
  end
end
