defmodule Custode.MCPJournalReadTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.Identity
  alias Custode.Notebook

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{mcp: true})
    {:ok, operator_token} = Identity.operator_token()

    %{
      routine: routine,
      workspace: workspace,
      own: session(Identity.mint(:routine, routine.id)),
      operator: session(operator_token)
    }
  end

  test "both endpoints discover the bounded contract and workers are granted it", ctx do
    sub = session(Identity.mint(:sub_agent, uid("sub")), "/mcp/memory")

    for client <- [ctx.own, sub] do
      %{"result" => %{"tools" => tools}} = rpc(client, "tools/list", %{})
      tool = Enum.find(tools, &(&1["name"] == "journal_read"))
      assert tool
      schema = tool["inputSchema"]
      assert Map.get(schema, "required", []) == []
      properties = schema["properties"]
      assert properties["routine_id"]["type"] == "string"
      assert properties["agent_id"]["type"] == "string"
      assert properties["search"]["type"] == "string"
      assert properties["limit"]["type"] == "integer"
      assert properties["limit"]["description"] =~ "default 20, range 1..100"
      assert properties["live_only"]["type"] == "boolean"
      assert properties["live_only"]["description"] =~ "default true"
    end

    assert "mcp__custode__journal_read" in Custode.Routine.mcp_tools(:backlog_worker)
    %{"result" => %{"tools" => tools}} = rpc(sub, "tools/list", %{})
    refute Enum.any?(tools, &(&1["name"] in ["journal_append", "start_agent"]))
  end

  test "a restricted routine appends and reads its own journal without the rendered file", ctx do
    %{"entry_id" => id} = call(ctx.own, "journal_append", %{title: "Research", body: "Found it"})
    :ok = File.rm(Path.join(ctx.workspace, "journal.md"))

    assert %{"entries" => [entry]} = call(ctx.own, "journal_read")
    assert entry["id"] == id
    assert entry["title"] == "Research"
    assert entry["body"] == "Found it"
    assert entry["compacted_at"] == nil
    assert {:ok, _stamp, 0} = DateTime.from_iso8601(entry["inserted_at"])
    assert Enum.sort(Map.keys(entry)) == ~w(body compacted_at id inserted_at title)
    refute File.exists?(Path.join(ctx.workspace, "journal.md"))
  end

  test "both identity names work for a routine and the authenticated operator", ctx do
    {:ok, entry} = Notebook.journal_append(ctx.routine.id, "mine")

    for client <- [ctx.own, ctx.operator], key <- [:routine_id, :agent_id] do
      assert %{"entries" => [%{"id" => id}]} =
               call(client, "journal_read", %{key => ctx.routine.id})

      assert id == entry.id
    end

    assert %{"entries" => [%{"id" => id}]} =
             call(ctx.operator, "journal_read", %{routine_id: " ", agent_id: ctx.routine.id})

    assert id == entry.id

    assert %{"entries" => [%{"id" => ^id}]} =
             call(ctx.operator, "journal_read", %{
               routine_id: ctx.routine.id,
               agent_id: uid("ignored-alias")
             })
  end

  test "routines, the caretaker and subagents cannot select a sibling or parent", ctx do
    {:ok, _entry} = Notebook.journal_append(ctx.routine.id, "private journal")
    sibling_id = uid("sibling")

    put_env!(:routines, [
      %{
        id: ctx.routine.id,
        role: :backlog_worker,
        cron: :manual,
        workspace: ctx.workspace,
        prompt: "x"
      },
      %{id: sibling_id, role: :assistant, cron: :manual, workspace: ctx.workspace, prompt: "x"},
      %{id: "custode", role: :caretaker, cron: :manual, workspace: ctx.workspace, prompt: "x"}
    ])

    clients = [
      session(Identity.mint(:routine, sibling_id)),
      session(Identity.mint(:routine, "custode")),
      session(Identity.mint(:sub_agent, uid("sub")), "/mcp/memory")
    ]

    for client <- clients, key <- [:routine_id, :agent_id] do
      error = tool_error(client, "journal_read", %{key => ctx.routine.id})
      assert error =~ "may not read #{ctx.routine.id}'s records"
      refute error =~ "private journal"
    end
  end

  test "subagents read only their own journal through the memory endpoint", ctx do
    sub_id = uid("sub")
    sub = session(Identity.mint(:sub_agent, sub_id), "/mcp/memory")
    {:ok, own} = Notebook.journal_append(sub_id, "child result")
    {:ok, _parent} = Notebook.journal_append(ctx.routine.id, "parent result")

    for args <- [%{}, %{agent_id: sub_id}, %{routine_id: sub_id}] do
      assert %{"entries" => [%{"id" => id, "body" => "child result"}]} =
               call(sub, "journal_read", args)

      assert id == own.id
    end
  end

  test "empty journals return an empty list and operators must select an identity", ctx do
    assert call(ctx.own, "journal_read") == %{"entries" => []}

    assert call(ctx.operator, "journal_read", %{routine_id: uid("empty")}) ==
             %{"entries" => []}

    assert tool_error(ctx.operator, "journal_read", %{}) =~ "whose records?"
  end

  test "default, selected and maximum limits bound results newest first", ctx do
    now = DateTime.utc_now()

    entries =
      for n <- 1..101 do
        %{
          routine_id: ctx.routine.id,
          body: "entry #{n}",
          inserted_at: now,
          updated_at: now
        }
      end

    {101, _rows} = Custode.Repo.insert_all(Notebook.JournalEntry, entries)
    %{"entries" => default} = call(ctx.own, "journal_read")
    assert length(default) == 20
    assert hd(default)["body"] == "entry 101"
    ids = Enum.map(default, & &1["id"])
    assert ids == Enum.sort(ids, :desc)

    %{"entries" => one} = call(ctx.own, "journal_read", %{limit: 1})
    assert one == [hd(default)]
    %{"entries" => maximum} = call(ctx.own, "journal_read", %{limit: 100})
    assert length(maximum) == 100
    assert List.last(maximum)["body"] == "entry 2"
  end

  test "search uses the notebook's case-insensitive title and body filtering", ctx do
    {:ok, title_match} = Notebook.journal_append(ctx.routine.id, "coast", title: "LIGURIA")
    {:ok, body_match} = Notebook.journal_append(ctx.routine.id, "liguria in November")
    {:ok, _other} = Notebook.journal_append(ctx.routine.id, "other work")
    {:ok, _sibling} = Notebook.journal_append(uid("sibling"), "liguria elsewhere")

    %{"entries" => matches} = call(ctx.own, "journal_read", %{search: "LiGuRiA"})
    assert Enum.map(matches, & &1["id"]) == [body_match.id, title_match.id]
    assert call(ctx.own, "journal_read", %{search: "absent"}) == %{"entries" => []}
    %{"entries" => unfiltered} = call(ctx.own, "journal_read", %{search: ""})
    assert length(unfiltered) == 3
  end

  test "live entries are the default and compacted history is explicitly readable", ctx do
    {:ok, original} = Notebook.journal_append(ctx.routine.id, "original evidence")

    assert call(ctx.own, "compact_journal", %{summary: "retained conclusion"}) == %{
             "summarized" => 1
           }

    assert %{"entries" => [%{"body" => "retained conclusion", "compacted_at" => nil}]} =
             call(ctx.own, "journal_read")

    assert call(ctx.own, "journal_read", %{search: "original"}) == %{"entries" => []}

    assert %{"entries" => [entry]} =
             call(ctx.own, "journal_read", %{search: "original", live_only: false})

    assert entry["id"] == original.id
    assert {:ok, _stamp, 0} = DateTime.from_iso8601(entry["compacted_at"])
    %{"entries" => history} = call(ctx.own, "journal_read", %{live_only: false})
    assert length(history) == 2
  end

  test "invalid limits and field types fail at the authenticated HTTP boundary", ctx do
    for limit <- [0, -1, 101] do
      assert tool_error(ctx.own, "journal_read", %{limit: limit}) =~
               "limit must be a whole number from 1 through 100"
    end

    arguments = [
      %{limit: 1.5},
      %{limit: "20"},
      %{limit: false},
      %{routine_id: []},
      %{agent_id: 7},
      %{search: true},
      %{live_only: "false"}
    ]

    for args <- arguments do
      assert %{"error" => %{"code" => -32_602}} =
               rpc_error(ctx.own, "tools/call", %{name: "journal_read", arguments: args})
    end

    assert call(ctx.own, "journal_read", %{limit: nil, search: nil, live_only: nil}) ==
             %{"entries" => []}
  end

  defp session(token, path \\ "/mcp") do
    client = %{
      url: "http://127.0.0.1:#{Custode.MCP.port()}#{path}",
      headers: [
        {"authorization", "Bearer " <> token},
        {"accept", "application/json, text/event-stream"}
      ]
    }

    response =
      post(client, %{
        jsonrpc: "2.0",
        id: 1,
        method: "initialize",
        params: %{
          protocolVersion: "2025-06-18",
          capabilities: %{},
          clientInfo: %{name: "journal-test", version: "0"}
        }
      })

    assert response.status == 200
    assert response.body["result"]["protocolVersion"] == "2025-06-18"
    assert Req.Response.get_header(response, "mcp-session-id") == []

    client = %{
      client
      | headers: [{"mcp-protocol-version", "2025-06-18"} | client.headers]
    }

    assert post(client, %{jsonrpc: "2.0", method: "notifications/initialized"}).status == 202
    client
  end

  defp call(client, tool, arguments \\ %{}) do
    %{"result" => %{"isError" => false, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    Jason.decode!(text)
  end

  defp tool_error(client, tool, arguments) do
    %{"result" => %{"isError" => true, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    text
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

  defp rpc_error(client, method, params) do
    response =
      post(client, %{
        jsonrpc: "2.0",
        id: System.unique_integer([:positive]),
        method: method,
        params: params
      })

    # Snodo carries an authenticated JSON-RPC error in a successful HTTP
    # exchange. Admission failures still use their transport-level 4xx status.
    assert response.status == 200
    decode(response.body)
  end

  defp post(client, body) do
    Req.post!(client.url, json: body, headers: client.headers, retry: false)
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
