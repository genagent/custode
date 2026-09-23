defmodule Custode.MCPCapabilitiesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.Identity

  setup do
    workspace = tmp_workspace!()
    worker_id = uid("worker")
    caretaker_id = uid("caretaker")

    put_env!(:routines, [
      %{id: worker_id, role: :backlog_worker, cron: :manual, workspace: workspace, prompt: "x"},
      %{id: caretaker_id, role: :caretaker, cron: :manual, workspace: workspace, prompt: "x"}
    ])

    previous_presence = Application.fetch_env(:custode, :presence_override)
    Application.delete_env(:custode, :presence_override)

    on_exit(fn ->
      case previous_presence do
        {:ok, value} -> Application.put_env(:custode, :presence_override, value)
        :error -> Application.delete_env(:custode, :presence_override)
      end
    end)

    {:ok, operator_token} = Identity.operator_token()

    %{
      operator_token: operator_token,
      worker_token: Identity.mint(:routine, worker_id),
      caretaker_token: Identity.mint(:routine, caretaker_id),
      sub_token: Identity.mint(:sub_agent, uid("sub"))
    }
  end

  test "endpoint admission follows identity kind", ctx do
    assert initialize(ctx.operator_token, "/mcp").status == 200
    assert initialize(ctx.worker_token, "/mcp").status == 200
    assert initialize(ctx.caretaker_token, "/mcp").status == 200
    assert initialize(ctx.sub_token, "/mcp").status == 403
    assert initialize(Identity.mint(:routine, uid("retired")), "/mcp").status == 403

    assert initialize(ctx.sub_token, "/mcp/memory").status == 200
    assert initialize(ctx.operator_token, "/mcp/memory").status == 403
    assert initialize(ctx.worker_token, "/mcp/memory").status == 403
  end

  test "discovery exposes only authorized capabilities", ctx do
    operator = session(ctx.operator_token, "/mcp")
    worker = session(ctx.worker_token, "/mcp")
    caretaker = session(ctx.caretaker_token, "/mcp")
    sub = session(ctx.sub_token, "/mcp/memory")

    operator_tools = tool_names(operator)
    worker_tools = tool_names(worker)
    caretaker_tools = tool_names(caretaker)

    assert "set_presence" in operator_tools
    assert "drain" in operator_tools

    assert "journal_append" in worker_tools
    assert "repo_open_pr" in worker_tools
    refute "beat" in worker_tools
    refute "list_attention" in worker_tools

    assert "journal_append" in caretaker_tools
    assert "beat" in caretaker_tools
    assert "list_attention" in caretaker_tools
    assert "provision_owned_checkout" in caretaker_tools
    refute "set_presence" in caretaker_tools
    refute "drain" in caretaker_tools
    refute "answer_ask" in caretaker_tools
    refute "dismiss_ask" in caretaker_tools

    assert tool_names(sub) == ~w(forget journal_read recall remember)
  end

  test "generated allowlists are a compact projection of the same policy", _ctx do
    worker = Custode.Routine.mcp_tools(:backlog_worker)
    caretaker = Custode.Routine.mcp_tools(:caretaker)

    assert "mcp__custode__journal_append" in worker
    refute "mcp__custode__beat" in worker

    assert "mcp__custode__beat" in caretaker
    refute "mcp__custode__list_attention" in caretaker
    refute "mcp__custode__provision_owned_checkout" in caretaker
    refute "mcp__custode__answer_ask" in caretaker
    refute "mcp__custode__dismiss_ask" in caretaker
  end

  test "blind calls are refused before side effects", ctx do
    worker = session(ctx.worker_token, "/mcp")
    caretaker = session(ctx.caretaker_token, "/mcp")

    for client <- [worker, caretaker] do
      response = rpc(client, "tools/call", %{name: "set_presence", arguments: %{mode: "away"}})
      assert get_in(response, ["error", "message"]) =~ "MCP capability refused"
      assert Application.get_env(:custode, :presence_override) == nil
    end
  end

  defp tool_names(client) do
    %{"result" => %{"tools" => tools}} = rpc(client, "tools/list", %{})
    Enum.map(tools, & &1["name"])
  end

  defp session(token, path) do
    response = initialize(token, path)
    assert response.status == 200
    [session_id] = Req.Response.get_header(response, "mcp-session-id")

    client = %{
      url: url(path),
      headers: headers(token) ++ [{"mcp-session-id", session_id}]
    }

    assert post(client, %{jsonrpc: "2.0", method: "notifications/initialized"}).status == 202
    client
  end

  defp initialize(token, path) do
    client = %{url: url(path), headers: headers(token)}

    post(client, %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "capability-test", version: "0"}
      }
    })
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

  defp url(path), do: "http://127.0.0.1:#{Custode.MCP.port()}#{path}"

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
