defmodule Custode.IdentityTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.MCP.Identity
  alias Custode.MCP.MemoryTools
  alias Custode.MCP.NotebookTools
  alias Custode.MCP.Router
  alias Custode.MCP.Tools
  alias ObanClaude.Agent
  alias Plug.Conn
  alias Plug.Test

  defp frame_for(kind, id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}

  test "mint/verify round-trips; re-minting revokes; garbage fails" do
    token = Identity.mint(:routine, "alpha")
    assert {:ok, %{kind: :routine, id: "alpha"}} = Identity.verify(token)

    fresh = Identity.mint(:routine, "alpha")
    assert :error = Identity.verify(token)
    assert {:ok, _identity} = Identity.verify(fresh)
    assert :error = Identity.verify("nope")
  end

  test "the HTTP surface 401s without a token and works with the operator token" do
    url = "http://127.0.0.1:#{Custode.MCP.port()}/mcp"

    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "t", version: "0"}
      }
    }

    accept = [{"accept", "application/json, text/event-stream"}]

    {:ok, %{status: 401}} = Req.post(url, json: body, headers: accept, retry: false)

    {:ok, token} = Identity.operator_token()

    {:ok, %{status: 200}} =
      Req.post(url,
        json: body,
        headers: [{"authorization", "Bearer " <> token} | accept],
        retry: false
      )
  end

  test "only an authenticated operator can mark an MCP request as CLI-originated" do
    {:ok, operator_token} = Identity.operator_token()

    operator_conn =
      Test.conn(:post, "/mcp")
      |> Conn.put_req_header("authorization", "Bearer " <> operator_token)
      |> Conn.put_req_header("x-custode-origin", "cli")
      |> Router.authenticate([])

    assert operator_conn.assigns.custode_transport == :cli

    routine_token = Identity.mint(:routine, "worker")

    routine_conn =
      Test.conn(:post, "/mcp")
      |> Conn.put_req_header("authorization", "Bearer " <> routine_token)
      |> Conn.put_req_header("x-custode-origin", "cli")
      |> Router.authenticate([])

    assert routine_conn.assigns.custode_transport == :mcp
  end

  test "a routine cannot decide a sibling routine's gate; its own sub-agents are fine" do
    workspace = tmp_workspace!()
    caller = routine_fixture!(workspace, %{id: uid("caller")})
    sibling = routine_fixture!(workspace, %{id: uid("sibling")})

    put_env!(:routines, [
      %{id: caller.id, cron: :manual, workspace: workspace, prompt: "x"},
      %{id: sibling.id, cron: :manual, workspace: workspace, prompt: "x"}
    ])

    test_pid = self()

    {:ok, _pid} =
      Agent.start_agent(sibling.id,
        enqueue_fun: fn _a, _m ->
          send(test_pid, :enqueued)
          {:ok, :queued}
        end
      )

    on_exit(fn -> Agent.stop_agent(sibling.id) end)

    :processing = Agent.submit_prompt(sibling.id, "go")

    :ok =
      Agent.job_finished(
        sibling.id,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "act"})}
      )

    {:ok, {:awaiting_permission, action}} = Agent.await(sibling.id, :awaiting_permission, 1_000)

    # sibling routine caller: refused, gate untouched
    reply =
      Tools.RejectAction.execute(
        %{agent_id: sibling.id, action_id: action.id},
        frame_for(:routine, caller.id)
      )

    assert tool_error(reply) =~ "may not decide routine"
    {:ok, {:awaiting_permission, _still}} = Agent.status(sibling.id)

    # operator frame: allowed
    reply =
      Tools.RejectAction.execute(
        %{agent_id: sibling.id, action_id: action.id, reason: "no"},
        frame_for(:operator, "operator")
      )

    assert tool_json(reply)
    {:ok, :idle} = Agent.await(sibling.id, :idle, 1_000)

    # sub-agent targets are not routines: gate ops allowed for routines
    sub = start_stub_agent!()
    :processing = Agent.submit_prompt(sub, "go")

    :ok =
      Agent.job_finished(
        sub,
        {:ok, structured_result(%{"directive" => "request_permission", "action" => "sub act"})}
      )

    {:ok, {:awaiting_permission, sub_action}} = Agent.await(sub, :awaiting_permission, 1_000)

    reply =
      Tools.RejectAction.execute(
        %{agent_id: sub, action_id: sub_action.id},
        frame_for(:routine, caller.id)
      )

    assert tool_json(reply)
  end

  test "notebook and memory writes are self-scoped for routines; operator passes" do
    workspace = tmp_workspace!()
    own = routine_fixture!(workspace, %{id: uid("own")})
    other = uid("other")

    reply =
      NotebookTools.JournalAppend.execute(
        %{routine_id: other, body: "sneaky"},
        frame_for(:routine, own.id)
      )

    assert tool_error(reply) =~ "may not write"

    reply =
      MemoryTools.Remember.execute(
        %{agent_id: other, key: "k", value: "v"},
        frame_for(:routine, own.id)
      )

    assert tool_error(reply) =~ "may not write"

    # own records fine; operator (and bare test frames) unrestricted
    reply =
      NotebookTools.JournalAppend.execute(
        %{routine_id: own.id, body: "mine"},
        frame_for(:routine, own.id)
      )

    assert tool_json(reply)

    reply =
      MemoryTools.Remember.execute(
        %{agent_id: other, key: "k", value: "v"},
        %Anubis.Server.Frame{}
      )

    assert tool_json(reply)

    # compaction is a notebook write too: self-scoped (#214)
    reply =
      NotebookTools.CompactJournal.execute(
        %{routine_id: other, summary: "not mine to fold"},
        frame_for(:routine, own.id)
      )

    assert tool_error(reply) =~ "may not write"

    # a panel proposal is self-scoped as well (#100)
    reply =
      NotebookTools.SetPanel.execute(
        %{routine_id: other, html: "<b>not my page</b>"},
        frame_for(:routine, own.id)
      )

    assert tool_error(reply) =~ "may not write"
  end

  # #488: check_self used to refuse only a :routine caller, so everyone else
  # fell through to :ok
  test "a sub-agent writes only its own records, not its parent's or a sibling's" do
    workspace = tmp_workspace!()
    parent = routine_fixture!(workspace, %{id: uid("parent")})
    sibling = routine_fixture!(workspace, %{id: uid("sibling")})
    sub = uid("sub")

    for target <- [parent.id, sibling.id] do
      reply =
        MemoryTools.Remember.execute(
          %{agent_id: target, key: "k", value: "planted"},
          frame_for(:sub_agent, sub)
        )

      assert tool_error(reply) =~ "#{sub} may not write #{target}'s records"
      assert Custode.Memory.recall(target, "k") == :error

      reply =
        NotebookTools.JournalAppend.execute(
          %{routine_id: target, body: "sneaky"},
          frame_for(:sub_agent, sub)
        )

      assert tool_error(reply) =~ "may not write"
    end

    # its own memories are its own
    reply =
      MemoryTools.Remember.execute(
        %{agent_id: sub, key: "k", value: "mine"},
        frame_for(:sub_agent, sub)
      )

    assert tool_json(reply)
    assert Custode.Memory.recall(sub, "k") == {:ok, "mine"}

    # and reads stay open: that is the written rule, not an accident
    :ok = Custode.Memory.remember(parent.id, "note", "readable")
    reply = MemoryTools.Recall.execute(%{agent_id: parent.id}, frame_for(:sub_agent, sub))
    assert inspect(tool_json(reply)) =~ "readable"
  end

  test "per-routine configs carry bearer headers; sub-agent configs mint on demand" do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{mcp: true})

    :ok = Custode.MCP.write_config!()
    on_exit(fn -> File.rm(Custode.MCP.config_path(routine.id)) end)

    config = Custode.MCP.config_path(routine.id) |> File.read!() |> Jason.decode!()
    assert "Bearer " <> token = config["mcpServers"]["custode"]["headers"]["Authorization"]
    assert {:ok, %{kind: :routine}} = Identity.verify(token)

    sub_id = uid("sub")
    path = Custode.MCP.write_sub_agent_config!(sub_id)
    on_exit(fn -> File.rm(path) end)

    sub_config = path |> File.read!() |> Jason.decode!()
    assert "Bearer " <> sub_token = sub_config["mcpServers"]["memory"]["headers"]["Authorization"]
    assert {:ok, %{kind: :sub_agent, id: ^sub_id}} = Identity.verify(sub_token)
  end
end
