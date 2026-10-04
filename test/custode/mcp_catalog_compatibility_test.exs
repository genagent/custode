defmodule Custode.MCPCatalogCompatibilityTest do
  use ExUnit.Case, async: false
  alias Custode.Test.CatalogProof
  alias Custode.MCP.Snodo, as: CustodeSnodo
  alias Snodo.{Client, Client.Subscription}
  @versions ["2025-06-18", "2025-11-25", "2026-07-28"]

  setup do
    state = start_supervised!({Agent, fn -> CatalogProof.state() end})
    executor = start_supervised!({Snodo.Server.Executor, []})
    CatalogProof.publish(state, 1)

    server =
      start_supervised!(
        {Bandit,
         plug: {CatalogProof.Endpoint, state: state, executor: executor},
         ip: {127, 0, 0, 1},
         port: 0}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    %{state: state, url: "http://127.0.0.1:#{port}/mcp"}
  end

  test "three pinned dialects enforce discovery and invocation for every catalog kind", ctx do
    for version <- @versions do
      client = connect(ctx.url, version)
      assert catalogs(client) == ["fixture_read_v1", "fixture_prompt_v1", "fixture_resource_v1"]

      assert {:ok, %{"content" => [%{"text" => ":fixture_owner"}]}} =
               Client.call_tool(client, "fixture_read_v1", %{})

      assert {:ok, %{"messages" => [%{"content" => %{"text" => ":fixture_owner"}}]}} =
               Client.get_prompt(client, "fixture_prompt_v1")

      assert {:ok, %{"contents" => [%{"text" => ":fixture_owner"}]}} =
               Client.read_resource(client, "fixture://v1/context")

      assert :ok = Client.close(client)
      denied = connect(ctx.url, version, "fixture-other")
      assert catalogs(denied) == []

      assert {:error, %Snodo.Error{code: -32_003}} =
               Client.call_tool(denied, "fixture_read_v1", %{})

      assert {:error, %Snodo.Error{code: -32_003}} =
               Client.get_prompt(denied, "fixture_prompt_v1")

      assert {:error, %Snodo.Error{code: -32_003}} =
               Client.read_resource(denied, "fixture://v1/context")

      assert :ok = Client.close(denied)
    end
  end

  test "replacement changes fresh discovery and invocation while old runtime values remain immutable",
       ctx do
    old = Agent.get(ctx.state, & &1.runtime)

    for version <- @versions do
      CatalogProof.publish(ctx.state, 1)
      before = connect(ctx.url, version)
      assert catalogs(before) == ["fixture_read_v1", "fixture_prompt_v1", "fixture_resource_v1"]
      CatalogProof.publish(ctx.state, 2)
      assert catalogs(before) == ["fixture_read_v2", "fixture_prompt_v2", "fixture_resource_v2"]

      assert {:error, %Snodo.Error{code: -32_602}} =
               Client.call_tool(before, "fixture_read_v1", %{})

      assert :ok = Client.close(before)
      reconnected = connect(ctx.url, version)

      assert catalogs(reconnected) == [
               "fixture_read_v2",
               "fixture_prompt_v2",
               "fixture_resource_v2"
             ]

      assert :ok = Client.close(reconnected)
    end

    assert Map.keys(old.router.tools) == ["fixture_read_v1"]
    current = connect(ctx.url, "2026-07-28")
    Agent.update(ctx.state, &%{&1 | allowed: false})
    assert catalogs(current) == []

    assert {:error, %Snodo.Error{code: -32_003}} =
             Client.call_tool(current, "fixture_read_v2", %{})

    assert :ok = Client.close(current)
  end

  test "2026 HTTP subscription emits three list changes; legacy listen and current Custode remain unsupported",
       ctx do
    Agent.update(ctx.state, &%{&1 | notifications: true})
    CatalogProof.publish(ctx.state, 1)
    client = connect(ctx.url, "2026-07-28")

    filter = %{
      "toolsListChanged" => true,
      "promptsListChanged" => true,
      "resourcesListChanged" => true
    }

    assert {:ok, stream} = Client.listen(client, filter)
    assert stream.accepted == filter
    CatalogProof.publish(ctx.state, 2)

    for method <- [
          "notifications/tools/list_changed",
          "notifications/prompts/list_changed",
          "notifications/resources/list_changed"
        ] do
      assert {:notification, ^method, _metadata} = Subscription.next(stream, 2_000)
    end

    assert catalogs(client) == ["fixture_read_v2", "fixture_prompt_v2", "fixture_resource_v2"]
    assert :ok = Subscription.close(stream)
    assert :ok = Client.close(client)
    denied = connect(ctx.url, "2026-07-28", "fixture-other")
    assert {:error, %Snodo.Error{code: -32_003}} = Client.listen(denied, filter)
    Client.close(denied)

    Agent.update(ctx.state, &%{&1 | notifications: false})
    CatalogProof.publish(ctx.state, 2)

    for version <- ["2025-06-18", "2025-11-25"] do
      legacy = connect(ctx.url, version)
      assert {:error, %Snodo.Error{code: -32_601}} = Client.listen(legacy, filter)
      Client.close(legacy)
    end

    for {_path, plug} <- CustodeSnodo.plug_options() do
      assert plug.runtime.subscription_source == nil
      refute get_in(plug.runtime.capabilities, ["tools", "listChanged"]) == true
    end
  end

  test "subscription filters and current fixture grant changes do not disclose unrelated events",
       ctx do
    Agent.update(ctx.state, &%{&1 | notifications: true})
    CatalogProof.publish(ctx.state, 1)
    client = connect(ctx.url, "2026-07-28")
    assert {:ok, stream} = Client.listen(client, %{"toolsListChanged" => true})
    CatalogProof.publish(ctx.state, 2)

    assert {:notification, "notifications/tools/list_changed", _params} =
             Subscription.next(stream, 2_000)

    assert {:error, :timeout} = Subscription.next(stream, 100)
    Agent.update(ctx.state, &%{&1 | allowed: false})
    assert {:closed, :complete} = Subscription.next(stream, 2_000)
    assert :ok = Client.close(client)
  end

  @tag :preview
  @tag timeout: 120_000
  test "installed Codex exposes catalog status without a model turn", ctx do
    assert System.get_env("CUSTODE_NONPAID_CATALOG_PROOF") == "1"

    {output, status} =
      System.cmd("python3", ["-B", "spikes/capabilities/native_catalog_probe.py", ctx.url],
        stderr_to_stdout: false
      )

    assert status == 0, output
    result = Jason.decode!(output)
    assert result["model_calls"] == 0
    assert result["claude"]["state"] == "observed"

    assert Enum.all?(
             result["claude"]["observations"],
             &(&1["connected_health_message"] and &1["exit_code"] == 0)
           )

    assert result["before"]["tools"] == ["fixture_read_v1"]
    assert result["fresh_process_status"]["tools"] == ["fixture_read_v2"]

    report =
      result
      |> Map.put("server_observations", Agent.get(ctx.state, &Enum.reverse(&1.observations)))
      |> Map.put("http_protocol_versions", Agent.get(ctx.state, & &1.http_versions))

    if path = System.get_env("CUSTODE_NONPAID_CATALOG_REPORT") do
      File.write!(path, Jason.encode!(report, pretty: true))
      File.chmod!(path, 0o600)
    end
  end

  defp connect(url, version, token \\ "fixture-owner") do
    {:ok, client} =
      Client.connect({:http, url},
        protocol: version,
        headers: [{"authorization", "Bearer " <> token}],
        timeout: 3_000
      )

    client
  end

  defp catalogs(client) do
    {:ok, tools} = Client.list_tools(client)
    {:ok, prompts} = Client.list_prompts(client)
    {:ok, resources} = Client.list_resources(client)
    Enum.map(tools ++ prompts ++ resources, & &1["name"])
  end
end
