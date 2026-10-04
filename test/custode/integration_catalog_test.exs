defmodule Custode.IntegrationCatalogTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.{IntegrationCatalog, Repo, Routine, Workflow}
  alias Custode.IntegrationCatalog.{Override, Request}
  alias Custode.MCP.CallContext
  alias Custode.MCP.Tools.RunJob
  alias Custode.Workflow.{Node, Runner, Stage}
  alias Snodo.Client

  @operator %{kind: :operator, id: "catalog-operator"}

  defmodule Endpoint do
    @behaviour Plug
    def init(opts), do: opts

    def call(conn, opts) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "tools/list" ->
            %{
              "tools" =>
                Enum.map(["package_info", "new_write"], fn name ->
                  %{
                    "name" => name,
                    "description" => "fixture capability",
                    "inputSchema" => %{"type" => "object"}
                  }
                end)
            }

          "tools/call" ->
            send(
              opts[:observer],
              {:invoked, request["params"]["name"],
               Plug.Conn.get_req_header(conn, "authorization")}
            )

            %{"content" => [%{"type" => "text", "text" => "local package documentation"}]}
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{jsonrpc: "2.0", id: request["id"], result: result})
      )
    end
  end

  setup do
    name = uid("fixture-docs")

    server =
      start_supervised!({Bandit, plug: {Endpoint, observer: self()}, ip: {127, 0, 0, 1}, port: 0})

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    integration = %{
      name: name,
      type: :http,
      url: "http://127.0.0.1:#{port}/mcp",
      read_only: true,
      allowed: ["mcp__#{name}__package_info"]
    }

    put_env!(:external_mcp_servers, [integration])

    on_exit(fn ->
      Repo.delete_all(from(r in Override, where: r.name == ^name))
      Repo.delete_all(Request)
    end)

    %{name: name, integration: integration}
  end

  test "every current provider path loads its config and actually invokes the allowed read",
       ctx do
    routine = routine_fixture!(tmp_workspace!(), %{mcp: true})
    Custode.MCP.write_routine_config!(routine.id)
    on_exit(fn -> File.rm(Custode.MCP.config_path(routine.id)) end)
    standing = Routine.tick_args(routine)["start"]["args"]
    helper_id = uid("catalog-helper")
    memory = Custode.MCP.write_sub_agent_config!(helper_id)
    on_exit(fn -> File.rm(memory) end)

    helper =
      Routine.sub_agent_args(tmp_workspace!(), %{mcp_config_path: memory, agent_id: helper_id})

    refute Enum.any?(helper["allowed_tools"], &String.starts_with?(&1, "mcp__custode"))

    frame = %CallContext{assigns: %{custode_identity: @operator}}

    result =
      RunJob.execute(
        %{prompt: "read docs", report_inbox: Path.join(tmp_workspace!(), "inbox")},
        frame
      )
      |> tool_json()

    one_shot = Repo.get!(Oban.Job, result["job_id"]).args

    workflow =
      Workflow.new!(uid("catalog-workflow"), [
        %Stage{
          name: :read,
          nodes: [
            %Node{name: :docs, prompt: "read docs", schema: %{"type" => "object"}}
          ]
        }
      ])

    put_env!(:extra_workflows, %{workflow.name => workflow})
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")

    node =
      Repo.one!(
        from(j in Oban.Job,
          where:
            j.worker == "Custode.Workflow.NodeJob" and
              fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
        )
      )

    for args <- [standing, helper, one_shot, node.args] do
      assert args["strict_mcp_config"] == true
      assert is_map(args["custode_integration_capture"])

      assert {:ok, _result} =
               ObanClaude.run(Map.put(args, "prompt", "read docs"),
                 query_fun: fn _prompt, opts ->
                   invoke_claude!(opts, ctx.name)
                   {:ok, ObanClaude.Testing.result(result: "fixture completed")}
                 end
               )

      assert_receive {:invoked, "package_info", []}
      refute_receive {:invoked, "new_write", _}, 10
    end

    codex = routine_fixture!(tmp_workspace!(), %{mcp: true, provider: :codex})
    Custode.MCP.write_routine_config!(codex.id)
    on_exit(fn -> File.rm(Custode.MCP.config_path(codex.id)) end)
    args = Routine.tick_args(codex)["start"]["args"]

    assert {:ok, _result} =
             ObanCodex.run(Map.put(args, "prompt", "read docs"),
               query_fun: fn _prompt, opts ->
                 invoke_codex!(opts, ctx.name)
                 {:ok, ObanCodex.Testing.result("fixture completed")}
               end
             )

    assert_receive {:invoked, "package_info", []}
  end

  test "disable and worker deny preserve captured files and reject stale revisions", ctx do
    context = %{agent_id: "owner", audience: "routine", provider: "claude"}
    first = IntegrationCatalog.capture(context)
    bytes = File.read!(first.config_path)
    [definition] = IntegrationCatalog.definitions()

    assert {:ok, updated} =
             IntegrationCatalog.update_access(
               @operator,
               ctx.name,
               definition.revision,
               uid("disable"),
               %{"enabled" => false}
             )

    second = IntegrationCatalog.capture(context)
    assert second.config_path == nil
    assert [%{disposition: "disabled"}] = second.entries
    assert File.read!(first.config_path) == bytes

    assert {:error, :revision_conflict} =
             IntegrationCatalog.update_access(
               @operator,
               ctx.name,
               definition.revision,
               uid("stale"),
               %{"enabled" => true}
             )

    assert {:ok, _updated} =
             IntegrationCatalog.update_access(
               @operator,
               ctx.name,
               updated.revision,
               uid("deny"),
               %{"enabled" => true, "denied_agents" => ["owner"]}
             )

    assert [%{disposition: "worker_denied", endpoint: nil, allowed_tools: []}] =
             IntegrationCatalog.capture(context).entries

    assert IntegrationCatalog.capture(%{context | agent_id: "other"}).config_path
  end

  test "access retries are idempotent and do not expand manager authority", ctx do
    [definition] = IntegrationCatalog.definitions()
    key = uid("catalog-request")
    settings = %{"enabled" => false}

    assert {:ok, result} =
             IntegrationCatalog.update_access(
               @operator,
               ctx.name,
               definition.revision,
               key,
               settings
             )

    assert {:ok, repeated} =
             IntegrationCatalog.update_access(
               @operator,
               ctx.name,
               definition.revision,
               key,
               settings
             )

    assert Jason.encode!(result) == Jason.encode!(repeated)

    assert {:error, :idempotency_conflict} =
             IntegrationCatalog.update_access(@operator, ctx.name, definition.revision, key, %{
               "enabled" => true
             })

    assert {:error, _reason} =
             IntegrationCatalog.update_access(
               %{kind: :routine, id: "custode"},
               ctx.name,
               definition.revision,
               uid("denied"),
               settings
             )
  end

  test "explicit unsupported and unsafe access has no configuration or grants", ctx do
    cases = [
      {Map.put(ctx.integration, :allowed, ["mcp__" <> ctx.name]),
       "exact_tool_allowlist_required"},
      {Map.put(ctx.integration, :read_only, false), "read_only_declaration_required"},
      {Map.put(ctx.integration, :audiences, ["routine"]), "audience_denied"}
    ]

    for {integration, expected} <- cases do
      put_env!(:external_mcp_servers, [integration])

      captured =
        IntegrationCatalog.capture(%{
          agent_id: "helper",
          audience: "sub_agent",
          provider: "claude"
        })

      assert captured.config_path == nil
      assert [%{disposition: ^expected}] = captured.entries
    end

    put_env!(:external_mcp_servers, [Map.put(ctx.integration, :type, :sse)])

    captured =
      IntegrationCatalog.capture(%{agent_id: "worker", audience: "routine", provider: "codex"})

    assert captured.codex_overrides == []
    assert [%{disposition: "codex_sse_unsupported"}] = captured.entries
    put_env!(:external_mcp_servers, [ctx.integration])

    bypass =
      IntegrationCatalog.apply_claude(%{"permission_mode" => "bypass_permissions"}, %{
        agent_id: "worker",
        audience: "one_shot"
      })

    assert bypass["mcp_config"] == []

    assert [%{disposition: "bypass_permissions_not_supported"}] =
             bypass["custode_integration_capture"].entries
  end

  test "credential rotation creates a new private capture without leaking secrets into inspection",
       ctx do
    variable = "CUSTODE_CATALOG_TEST_TOKEN"
    previous = System.get_env(variable)

    on_exit(fn ->
      if previous, do: System.put_env(variable, previous), else: System.delete_env(variable)
    end)

    put_env!(:external_mcp_servers, [Map.put(ctx.integration, :credential_ref, variable)])
    context = %{agent_id: "owner", audience: "routine", provider: "claude"}
    System.put_env(variable, "fixture-secret-one")
    first = IntegrationCatalog.capture(context)
    assert {:ok, inspection} = IntegrationCatalog.inspect_for(@operator)
    refute Jason.encode!(inspection) =~ "fixture-secret-one"
    System.put_env(variable, "fixture-secret-two")
    second = IntegrationCatalog.capture(context)
    refute first.revision == second.revision
    assert File.read!(first.config_path) =~ "fixture-secret-one"
    assert File.read!(second.config_path) =~ "fixture-secret-two"
    assert Bitwise.band(File.stat!(second.config_path).mode, 0o777) == 0o600

    invoke_claude!(
      [mcp_config: [second.config_path], allowed_tools: second.allowed_tools],
      ctx.name
    )

    assert_receive {:invoked, "package_info", ["Bearer fixture-secret-two"]}
    codex = IntegrationCatalog.capture(%{context | provider: "codex"})
    refute Enum.join(codex.codex_overrides) =~ "fixture-secret"
    assert Enum.any?(codex.codex_overrides, &String.contains?(&1, "bearer_token_env_var"))
  end

  test "inspection and contract revisions never materialize files; unavailable endpoints stay observed failures",
       ctx do
    directory = Path.join(Path.dirname(Custode.MCP.config_path()), "integration_captures")
    before = Path.wildcard(Path.join(directory, "*")) |> Enum.sort()
    routine = routine_fixture!(tmp_workspace!(), %{mcp: true})
    assert is_binary(Routine.execution_revision(routine))
    assert {:ok, _facts} = IntegrationCatalog.inspect_for(@operator)
    assert Path.wildcard(Path.join(directory, "*")) |> Enum.sort() == before
    put_env!(:external_mcp_servers, [Map.put(ctx.integration, :url, "http://127.0.0.1:1/mcp")])

    capture =
      IntegrationCatalog.capture(%{agent_id: "owner", audience: "routine", provider: "claude"})

    assert [%{disposition: "configured"}] = capture.entries

    assert {:ok, client} =
             Client.connect({:http, "http://127.0.0.1:1/mcp"}, protocol: "2026-07-28")

    assert {:error, _reason} = Client.call_tool(client, "package_info", %{})
    assert :ok = Client.close(client)
  end

  test "missing credentials are withheld and approved continuations cannot replace the catalog",
       ctx do
    variable = "CUSTODE_CATALOG_MISSING_TOKEN"
    previous = System.get_env(variable)
    System.delete_env(variable)
    on_exit(fn -> if previous, do: System.put_env(variable, previous) end)
    put_env!(:external_mcp_servers, [Map.put(ctx.integration, :credential_ref, variable)])

    capture =
      IntegrationCatalog.capture(%{agent_id: "owner", audience: "routine", provider: "claude"})

    assert capture.config_path == nil
    assert [%{disposition: "credential_unavailable", allowed_tools: []}] = capture.entries
    put_env!(:external_mcp_servers, [ctx.integration])

    routine =
      routine_fixture!(tmp_workspace!(), %{
        mcp: true,
        approved_args: %{
          "permission_mode" => "accept_edits",
          "mcp_config" => ["unreviewed.json"],
          "allowed_tools" => ["mcp__unreviewed__*"]
        }
      })

    Custode.MCP.write_routine_config!(routine.id)
    on_exit(fn -> File.rm(Custode.MCP.config_path(routine.id)) end)
    start = Routine.tick_args(routine)["start"]
    assert start["approved_args"]["mcp_config"] == start["args"]["mcp_config"]
    assert start["approved_args"]["allowed_tools"] == start["args"]["allowed_tools"]
    assert start["approved_args"]["strict_mcp_config"]

    bypass =
      Routine.tick_args(%{routine | approved_args: %{"permission_mode" => "bypass_permissions"}})[
        "start"
      ]["approved_args"]

    assert bypass["mcp_config"] == [Custode.MCP.config_path(routine.id)]
    assert bypass["strict_mcp_config"]
  end

  defp invoke_claude!(opts, name) do
    config =
      Enum.find_value(opts[:mcp_config], fn path ->
        path |> File.read!() |> Jason.decode!() |> Map.fetch!("mcpServers") |> Map.get(name)
      end)

    assert "mcp__#{name}__package_info" in opts[:allowed_tools]
    refute "mcp__#{name}__new_write" in opts[:allowed_tools]
    invoke!(config["url"], config["headers"] || %{})
  end

  defp invoke_codex!(opts, name) do
    values =
      Map.new(
        Enum.filter(
          opts[:config_overrides],
          &String.starts_with?(&1, "mcp_servers." <> name <> ".")
        ),
        fn line ->
          [key, value] = String.split(line, "=", parts: 2)
          {key, Jason.decode!(value)}
        end
      )

    root = "mcp_servers." <> name
    assert values[root <> ".enabled_tools"] == ["package_info"]
    assert values[root <> ".required"]
    invoke!(values[root <> ".url"], %{})
  end

  defp invoke!(url, headers) do
    {:ok, client} =
      Client.connect({:http, url}, protocol: "2026-07-28", headers: Map.to_list(headers))

    assert {:ok, tools} = Client.list_tools(client)
    assert Enum.any?(tools, &(&1["name"] == "new_write"))

    assert {:ok, %{"content" => [%{"text" => "local package documentation"}]}} =
             Client.call_tool(client, "package_info", %{})

    assert :ok = Client.close(client)
  end
end
