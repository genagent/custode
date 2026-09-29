defmodule Custode.MCP.BootstrapToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.BootstrapTools.OperatorBootstrap
  alias Custode.MCP.Identity

  setup do
    worker_id = uid("worker")

    put_env!(:routines, [
      %{
        id: worker_id,
        role: :backlog_worker,
        cron: :manual,
        workspace: tmp_workspace!(),
        repo: "acme/" <> uid("bootstrap-repo"),
        prompt: "x"
      }
    ])

    {:ok, operator_token} = Identity.operator_token()

    %{
      operator_token: operator_token,
      worker_id: worker_id,
      worker_token: Identity.mint(:routine, worker_id)
    }
  end

  test "the operator can list and call operator_bootstrap", ctx do
    operator = session(ctx.operator_token)

    assert "operator_bootstrap" in tool_names(operator)
    assert "list_operator_messages" in tool_names(operator)

    text = call_text(operator, "operator_bootstrap", %{})
    result = Jason.decode!(text)

    assert result["schema_version"] == "custode.operator_bootstrap.v1"
    assert {:ok, id} = Custode.Installation.fetch()
    assert result["installation"]["id"] == id
    assert result["caller"]["kind"] == "operator"
    assert result["caller"]["verified"] == true
    assert result["caller"]["transport"] == "mcp"
    assert result["authority"]["scope"] == "all"
    assert is_integer(result["fleet"]["open_gates"])
    assert result["expand"] != []
  end

  test "the result exposes no token or filesystem path", ctx do
    text = call_text(session(ctx.operator_token), "operator_bootstrap", %{})
    database = :custode |> Application.get_env(Custode.Repo) |> Keyword.fetch!(:database)

    refute text =~ ctx.operator_token
    refute text =~ ctx.worker_token
    refute text =~ Path.expand(database)
    refute text =~ ".installation"
  end

  test "a routine can neither list nor call operator_bootstrap", ctx do
    worker = session(ctx.worker_token)

    refute "operator_bootstrap" in tool_names(worker)
    refute "list_operator_messages" in tool_names(worker)

    response = rpc(worker, "tools/call", %{name: "operator_bootstrap", arguments: %{}})

    assert get_in(response, ["error", "message"]) =~ "MCP capability refused"
    refute get_in(response, ["result", "isError"]) == false

    response = rpc(worker, "tools/call", %{name: "list_operator_messages", arguments: %{}})

    assert get_in(response, ["error", "message"]) =~ "MCP capability refused"
    refute get_in(response, ["result", "isError"]) == false
  end

  test "the handler itself refuses a non-operator caller" do
    frame = %Anubis.Server.Frame{
      assigns: %{custode_identity: %{kind: :routine, id: uid("routine")}}
    }

    assert Custode.TestHelpers.tool_error(OperatorBootstrap.execute(%{}, frame)) =~
             "requires the human operator"
  end

  test "the handler reports a tool error and creates no file when the id is not provisioned" do
    path = unprovision_installation!()

    text = Custode.TestHelpers.tool_error(OperatorBootstrap.execute(%{}, %Anubis.Server.Frame{}))

    assert text =~ "installation id unavailable"
    assert text =~ ":not_provisioned"
    refute text =~ ".installation"
    refute text =~ Path.dirname(path)

    assert Custode.Installation.fetch() == {:error, :not_provisioned}
    refute File.exists?(path)
    assert File.ls!(Path.dirname(path)) == []
  end

  defp tool_names(client) do
    %{"result" => %{"tools" => tools}} = rpc(client, "tools/list", %{})
    Enum.map(tools, & &1["name"])
  end

  defp call_text(client, tool, arguments) do
    %{"result" => %{"isError" => false, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    text
  end

  defp session(token) do
    version = "2025-06-18"

    response =
      post(%{url: url(), headers: headers(token)}, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: version,
          capabilities: %{},
          clientInfo: %{name: "bootstrap-test", version: "0"}
        }
      })

    assert response.status == 200

    client = %{url: url(), headers: headers(token) ++ [{"mcp-protocol-version", version}]}
    assert post(client, %{jsonrpc: "2.0", method: "notifications/initialized"}).status == 202
    client
  end

  defp rpc(client, method, params) do
    response =
      post(client, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      })

    assert response.status == 200
    decode(response.body)
  end

  defp post(client, body) do
    Req.post!(client.url, json: body, headers: client.headers, retry: false)
  end

  defp url, do: "http://127.0.0.1:#{Custode.MCP.port()}/mcp"

  defp headers(token) do
    [
      {"authorization", "Bearer " <> token},
      {"accept", "application/json, text/event-stream"}
    ]
  end

  defp decode(body) when is_map(body), do: body

  defp decode(body) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "data: " <> data -> Jason.decode!(data)
      _line -> nil
    end)
    |> Kernel.||(Jason.decode!(body))
  end
end
