defmodule Custode.MCPCapabilitiesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, Repo, Routine}
  alias Custode.MCP.{Capabilities, Identity, Tools}

  setup do
    worker_workspace = tmp_workspace!()
    caretaker_workspace = tmp_workspace!()
    worker_id = uid("worker")
    caretaker_id = uid("caretaker")
    repo = "acme/" <> uid("capability-repo")

    put_env!(:routines, [
      %{
        id: worker_id,
        role: :backlog_worker,
        cron: :manual,
        workspace: worker_workspace,
        repo: repo,
        prompt: "x"
      },
      %{
        id: caretaker_id,
        role: :caretaker,
        cron: :manual,
        workspace: caretaker_workspace,
        repo: repo,
        prompt: "x"
      }
    ])

    :ok = Custode.Repository.ensure_served(repo, worker_id)

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
      repo: repo,
      worker_id: worker_id,
      worker_workspace: worker_workspace,
      worker_token: Identity.mint(:routine, worker_id),
      caretaker_id: caretaker_id,
      caretaker_workspace: caretaker_workspace,
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
    assert "project_progress" in operator_tools
    assert "project_progress" in caretaker_tools
    refute "project_progress" in worker_tools

    assert "journal_append" in worker_tools
    assert "repo_open_pr" in worker_tools
    assert "repo_list_issues" in worker_tools
    refute "beat" in worker_tools
    refute "list_attention" in worker_tools

    for tool <- ~w(peer_send peer_reply peer_list peer_read peer_ack) do
      assert tool in worker_tools
      assert tool in caretaker_tools
      assert tool in operator_tools
      assert ("mcp__custode__" <> tool) in Custode.Routine.mcp_tools(:backlog_worker)
    end

    assert "journal_append" in caretaker_tools
    assert "beat" in caretaker_tools
    assert "list_attention" in caretaker_tools
    assert "provision_owned_checkout" in caretaker_tools
    refute "set_presence" in caretaker_tools
    refute "drain" in caretaker_tools
    refute "answer_ask" in caretaker_tools
    refute "dismiss_ask" in caretaker_tools

    assert tool_names(sub) ==
             ~w(forget integration_list journal_read recall remember return_context subject_context)
  end

  test "discovery follows the durable contract of an active old-revision turn", ctx do
    old_routine = Routine.get(ctx.worker_id)
    old_revision = Routine.execution_revision(old_routine)
    assert :ok = AgentAuthorizationSnapshot.put(old_routine, old_revision)

    job =
      %{"prompt" => "keep the captured authorization"}
      |> Oban.Job.new(
        worker: ObanClaude.Agent.Job,
        queue: :agents,
        meta: %{
          "agent_id" => ctx.worker_id,
          "agent_generation" => Ecto.UUID.generate(),
          "agent_turn_id" => Ecto.UUID.generate(),
          "config_revision" => old_revision
        }
      )
      |> Ecto.Changeset.change(state: "suspended")
      |> Repo.insert!()

    on_exit(fn -> Repo.delete!(Repo.reload!(job)) end)

    previous_routines = Application.fetch_env!(:custode, :routines)

    Application.put_env(
      :custode,
      :routines,
      Enum.map(previous_routines, fn
        %{id: id} = routine when id == ctx.worker_id -> %{routine | role: :caretaker}
        routine -> routine
      end)
    )

    on_exit(fn -> Application.put_env(:custode, :routines, previous_routines) end)

    new_routine = Routine.get(ctx.worker_id)
    new_revision = Routine.execution_revision(new_routine)
    assert :ok = AgentAuthorizationSnapshot.put(new_routine, new_revision)

    worker = session(ctx.worker_token, "/mcp")
    old_tools = tool_names(worker)

    assert "journal_append" in old_tools
    refute "beat" in old_tools
    refute "project_progress" in old_tools

    job
    |> Ecto.Changeset.change(state: "completed")
    |> Repo.update!()

    assert "beat" in Capabilities.authorized_tool_names(:main, %{
             kind: :routine,
             id: ctx.worker_id
           })

    assert "beat" in tool_names(worker)
    assert "project_progress" in tool_names(worker)
  end

  test "peer calls preserve authenticated authorship through the HTTP adapter", ctx do
    worker = session(ctx.worker_token, "/mcp")
    caretaker = session(ctx.caretaker_token, "/mcp")
    operator = session(ctx.operator_token, "/mcp")

    args = %{
      recipient: ctx.caretaker_id,
      sender: ctx.caretaker_id,
      kind: "request",
      subject: "Inspect a dependency",
      body: "This request is not permission to merge anything.",
      idempotency_key: uid("http-peer")
    }

    %{"message" => message} = call(worker, "peer_send", args)

    on_exit(fn ->
      Repo.delete_all(from(m in Custode.PeerMessage, where: m.id == ^message["id"]))
    end)

    assert message["sender"] == ctx.worker_id
    assert message["recipient"] == ctx.caretaker_id
    refute Map.has_key?(message, "idempotency_key")
    assert %{"message" => %{"id" => id}} = call(worker, "peer_send", args)
    assert id == message["id"]

    assert %{"messages" => [%{"id" => ^id}]} =
             call(caretaker, "peer_list", %{direction: "received", counterpart: ctx.worker_id})

    assert %{"message" => %{"acknowledged_at" => nil}} =
             call(operator, "peer_read", %{message_id: id})

    assert tool_error(operator, "peer_send", Map.delete(args, :sender)) =~ "access denied"
    assert tool_error(operator, "peer_ack", %{message_id: id}) =~ "access denied"
    assert tool_error(worker, "peer_ack", %{message_id: id}) =~ "access denied"

    assert %{"message" => %{"acknowledged_at" => acknowledged_at}} =
             call(caretaker, "peer_ack", %{message_id: id})

    assert is_binary(acknowledged_at)
  end

  test "routine discovery does not normalize unrelated roster fields" do
    id = uid("profile-worker")

    put_env!(:profiles, %{tester: %{role: :backlog_worker}})

    put_env!(:routines, [
      %{
        id: id,
        profile: :tester,
        system_prompt_file: "/missing/discovery-must-not-read-this"
      }
    ])

    tools = :routine |> Identity.mint(id) |> session("/mcp") |> tool_names()

    assert "journal_append" in tools
    assert "repo_open_pr" in tools
    refute "beat" in tools
  end

  test "generated allowlists are a compact projection of the same policy", _ctx do
    worker = Custode.Routine.mcp_tools(:backlog_worker)
    caretaker = Custode.Routine.mcp_tools(:caretaker)

    assert "mcp__custode__journal_append" in worker
    refute "mcp__custode__beat" in worker
    refute "mcp__custode__project_progress" in worker

    assert "mcp__custode__project_progress" in caretaker
    assert "mcp__custode__beat" in caretaker
    refute "mcp__custode__list_attention" in caretaker
    refute "mcp__custode__provision_owned_checkout" in caretaker
    refute "mcp__custode__answer_ask" in caretaker
    refute "mcp__custode__dismiss_ask" in caretaker
  end

  test "project digest shares the authorized fleet read without worker access", ctx do
    for token <- [ctx.operator_token, ctx.caretaker_token] do
      client = session(token, "/mcp")
      assert "project_report_digest" in tool_names(client)
      result = call(client, "project_report_digest", %{window_hours: 24})
      assert result["schema_version"] == "custode.project_report_digest.v1"
      assert Enum.any?(result["projects"], &(&1["owner"] == ctx.worker_id))
    end

    worker = session(ctx.worker_token, "/mcp")
    refute "project_report_digest" in tool_names(worker)
    response = rpc(worker, "tools/call", %{name: "project_report_digest", arguments: %{}})
    assert get_in(response, ["error", "message"]) =~ "MCP capability refused"
    sub = session(ctx.sub_token, "/mcp/memory")
    refute "project_report_digest" in tool_names(sub)

    assert %{"error" => _} =
             rpc(sub, "tools/call", %{name: "project_report_digest", arguments: %{}})

    assert Custode.InboxWakes.get(ctx.worker_id) == nil
  end

  test "project progress is an explicit read without sibling control authority", ctx do
    operator = session(ctx.operator_token, "/mcp")
    caretaker = session(ctx.caretaker_token, "/mcp")
    worker = session(ctx.worker_token, "/mcp")
    sub = session(ctx.sub_token, "/mcp/memory")

    for client <- [operator, caretaker] do
      result = call(client, "project_progress", %{routine_id: ctx.worker_id})
      assert result["schema_version"] == "custode.project_progress.v1"
      assert result["project"]["routine_id"] == ctx.worker_id
    end

    response =
      rpc(worker, "tools/call", %{
        name: "project_progress",
        arguments: %{
          routine_id: ctx.caretaker_id,
          actor: %{kind: "operator"}
        }
      })

    assert get_in(response, ["error", "message"]) =~ "MCP capability refused"

    assert %{"error" => _error} =
             rpc(sub, "tools/call", %{
               name: "project_progress",
               arguments: %{routine_id: ctx.worker_id}
             })

    assert tool_error(caretaker, "agent_status", %{agent_id: ctx.worker_id}) =~ "may not control"

    assert tool_error(caretaker, "prompt_agent", %{agent_id: ctx.worker_id, prompt: "start work"}) =~
             "may not control"

    assert Custode.InboxWakes.get(ctx.worker_id) == nil
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

  test "delegation calls are scoped to the recorded parent", ctx do
    child = uid("child")
    :ok = Custode.SubAgents.record_spawn!(child, ctx.worker_id, %{workspace: "/tmp"})
    on_exit(fn -> Custode.SubAgents.forget(child) end)

    parent = session(ctx.worker_token, "/mcp")
    sibling = session(ctx.caretaker_token, "/mcp")
    operator = session(ctx.operator_token, "/mcp")

    assert %{"agent_id" => ^child, "state" => "offline"} =
             call(parent, "agent_status", %{agent_id: child})

    assert %{"agent_id" => ^child, "state" => "offline"} =
             call(operator, "agent_status", %{agent_id: child})

    assert tool_error(sibling, "agent_status", %{agent_id: child}) =~ "belongs to parent"

    Custode.SubAgents.forget(child)
    assert tool_error(parent, "agent_status", %{agent_id: child}) =~ "not a recorded child"

    frame = %Custode.MCP.CallContext{
      assigns: %{custode_identity: %{kind: :sub_agent, id: uid("grandchild")}}
    }

    assert Custode.TestHelpers.tool_error(
             Tools.StartAgent.execute(%{agent_id: uid("nested"), workspace: "/tmp"}, frame)
           ) =~ "may not delegate"
  end

  test "blind job calls cannot escape the authenticated routine's paths or grant", ctx do
    worker = session(ctx.worker_token, "/mcp")
    operator = session(ctx.operator_token, "/mcp")
    own_inbox = Path.join(ctx.worker_workspace, "inbox")
    foreign_inbox = Path.join(ctx.caretaker_workspace, "inbox")
    before = length(jobs_for("Custode.OneShotJob"))

    assert tool_error(worker, "run_job", %{
             prompt: "inspect",
             workspace: ctx.caretaker_workspace,
             report_inbox: own_inbox
           }) =~ "may not use workspace"

    assert tool_error(worker, "run_job", %{
             prompt: "inspect",
             workspace: ctx.worker_workspace,
             report_inbox: foreign_inbox
           }) =~ "may not use report_inbox"

    assert tool_error(worker, "run_job", %{
             prompt: "inspect",
             workspace: ctx.worker_workspace,
             report_inbox: own_inbox,
             elevated: true
           }) =~ "no approved action in flight"

    assert length(jobs_for("Custode.OneShotJob")) == before

    assert %{"job_id" => job_id} =
             call(operator, "run_job", %{
               prompt: "inspect",
               workspace: ctx.caretaker_workspace,
               report_inbox: foreign_inbox,
               elevated: true
             })

    assert is_integer(job_id)
  end

  test "blind repository-fact calls keep record ownership and the operator override", ctx do
    number = System.unique_integer([:positive])
    {:ok, row} = Custode.Disowned.disown(ctx.worker_id, ctx.repo, number, "worker judgment")

    on_exit(fn ->
      if current = Custode.Disowned.get(ctx.repo, number), do: Custode.Repo.delete!(current)
    end)

    caretaker = session(ctx.caretaker_token, "/mcp")
    operator = session(ctx.operator_token, "/mcp")

    assert tool_error(caretaker, "repo_reclaim_pr", %{repo: ctx.repo, number: number}) =~
             "record owned by #{ctx.worker_id}"

    assert Custode.Disowned.get(ctx.repo, number).id == row.id

    assert %{"disowned" => false} =
             call(operator, "repo_reclaim_pr", %{repo: ctx.repo, number: number})

    assert Custode.Disowned.get(ctx.repo, number) == nil
  end

  defp tool_names(client) do
    %{"result" => %{"tools" => tools}} = rpc(client, "tools/list", %{})
    Enum.map(tools, & &1["name"])
  end

  defp call(client, tool, arguments) do
    %{"result" => %{"isError" => false, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    Jason.decode!(text)
  end

  defp tool_error(client, tool, arguments) do
    %{"result" => %{"isError" => true, "content" => [%{"text" => text} | _rest]}} =
      rpc(client, "tools/call", %{name: tool, arguments: arguments})

    text
  end

  defp session(token, path) do
    version = "2025-06-18"
    response = initialize(token, path, version)
    assert response.status == 200
    assert Req.Response.get_header(response, "mcp-session-id") == []

    client = %{
      url: url(path),
      headers: headers(token) ++ [{"mcp-protocol-version", version}]
    }

    assert post(client, %{jsonrpc: "2.0", method: "notifications/initialized"}).status == 202
    client
  end

  defp initialize(token, path, version \\ "2025-06-18") do
    client = %{url: url(path), headers: headers(token)}

    post(client, %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: version,
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
