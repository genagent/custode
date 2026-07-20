defmodule Custode.MCPToolsTest do
  # Tool handlers called directly with params + a bare Frame; the HTTP
  # transport is exercised separately (it is anubis's contract, not ours).
  # Queues never execute in test, so "started" sub-agents insert real rows in
  # oban_jobs that never run -- the full plumbing, zero claude.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.MCP.Tools
  alias ObanClaude.Agent

  @frame %Anubis.Server.Frame{}

  describe "list_routines / agent_status" do
    test "reports configured routines with live status" do
      routine = routine_fixture!(tmp_workspace!())

      json = tool_json(Tools.ListRoutines.execute(%{}, @frame))
      assert [%{"id" => id, "status" => ":offline"}] = json["routines"]
      assert id == routine.id
    end

    test "agent_status: offline vs running with the bookkeeping" do
      json = tool_json(Tools.AgentStatus.execute(%{agent_id: "ghost"}, @frame))
      assert json["state"] == "offline"

      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      json = tool_json(Tools.AgentStatus.execute(%{agent_id: id}, @frame))
      assert json["state"] == "running"
      assert json["turns"] == 0
    end
  end

  describe "start_agent / prompt_agent" do
    test "starts a sub-agent whose turns land in the real queue (unexecuted)" do
      workspace = tmp_workspace!()
      id = uid("sub")
      on_exit(fn -> Agent.stop_agent(id) end)

      json =
        tool_json(
          Tools.StartAgent.execute(%{agent_id: id, workspace: workspace, model: "haiku"}, @frame)
        )

      assert json == %{"agent_id" => id, "state" => "idle", "workspace" => workspace}

      json = tool_json(Tools.PromptAgent.execute(%{agent_id: id, prompt: "hello"}, @frame))
      assert json["delivered"] == true
      assert {:ok, :running} = Agent.await(id, :running, 1_000)

      [job] = jobs_for("ObanClaude.Agent.Job") |> Enum.filter(&(&1.meta["agent_id"] == id))
      assert job.args["prompt"] == "hello"
      assert job.args["model"] == "haiku"
      assert job.args["working_dir"] == workspace
      refute Map.has_key?(job.args, "mcp_config")
    end

    test "a missing workspace is a tool error, not a crash" do
      reply = Tools.StartAgent.execute(%{agent_id: "x", workspace: "/nope/nothing"}, @frame)
      assert tool_error(reply) =~ "not an existing directory"
    end

    test "prompting a non-running agent is a tool error" do
      reply = Tools.PromptAgent.execute(%{agent_id: "ghost", prompt: "x"}, @frame)
      assert tool_error(reply) =~ "agent_not_running"
    end
  end

  describe "await_agent / agent_history" do
    test "await returns the settled state with the latest result" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")
      :ok = Agent.job_finished(id, {:ok, result("all wrapped up")})

      json = tool_json(Tools.AwaitAgent.execute(%{agent_id: id, timeout_ms: 2_000}, @frame))
      assert json["state"] == "idle"
      assert json["timed_out"] == false
      assert json["last_result"] == "all wrapped up"
    end

    test "await surfaces a gated state atomically with its payload" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      :ok =
        Agent.job_finished(
          id,
          {:ok, structured_result(%{"directive" => "request_permission", "action" => "deploy"})}
        )

      json = tool_json(Tools.AwaitAgent.execute(%{agent_id: id, timeout_ms: 2_000}, @frame))
      assert json["state"] == "awaiting_permission"
      assert json["detail"] =~ "deploy"
    end

    test "await times out into the current state instead of failing" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "hang")

      json = tool_json(Tools.AwaitAgent.execute(%{agent_id: id, timeout_ms: 100}, @frame))
      assert json["state"] == "running"
      assert json["timed_out"] == true
    end

    test "history returns printable entries, bounded by last" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "one")
      :ok = Agent.job_finished(id, {:ok, result("done one")})
      {:ok, :idle} = Agent.await(id, :idle, 1_000)

      json = tool_json(Tools.AgentHistory.execute(%{agent_id: id, last: 1}, @frame))
      assert [entry] = json["entries"]
      assert entry =~ "done one"
    end
  end

  describe "approve_action / reject_action" do
    defp gated_agent! do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      :ok =
        Agent.job_finished(
          id,
          {:ok, structured_result(%{"directive" => "request_permission", "action" => "risky"})}
        )

      {:ok, {:awaiting_permission, %{id: action_id}}} =
        Agent.await(id, :awaiting_permission, 1_000)

      {id, action_id}
    end

    test "approve releases the gate into a new turn" do
      {id, action_id} = gated_agent!()

      json = tool_json(Tools.ApproveAction.execute(%{agent_id: id, action_id: action_id}, @frame))
      assert json["approved"] == action_id
      assert_receive {:enqueued, %{"prompt" => "Approved: " <> _rest = prompt}, _meta}
      assert prompt =~ "risky"
    end

    test "reject returns the agent to idle; a stale id is a tool error" do
      {id, action_id} = gated_agent!()

      reply = Tools.RejectAction.execute(%{agent_id: id, action_id: "act_stale"}, @frame)
      assert tool_error(reply) =~ "unknown_action"

      json =
        tool_json(
          Tools.RejectAction.execute(%{agent_id: id, action_id: action_id, reason: "no"}, @frame)
        )

      assert json["rejected"] == action_id
      assert {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end
  end

  describe "run_job and the one-shot report path" do
    test "enqueues a OneShotJob carrying the report address" do
      workspace = tmp_workspace!()
      inbox = Path.join(workspace, "inbox")

      json =
        tool_json(
          Tools.RunJob.execute(
            %{prompt: "count the files", report_inbox: inbox, tag: "count", model: "haiku"},
            @frame
          )
        )

      assert json["reports_to"] == inbox

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["prompt"] == "count the files"
      assert job.args["report_inbox"] == inbox
      assert job.args["tag"] == "count"
      assert job.args["model"] == "haiku"
    end

    test "a missing report_inbox directory is a tool error" do
      reply = Tools.RunJob.execute(%{prompt: "x", report_inbox: "/nope/inbox"}, @frame)
      assert tool_error(reply) =~ "report_inbox"
    end

    test "handle_result writes the completion note where the sweep will find it" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      job = %Oban.Job{
        id: 991,
        args: %{"prompt" => "count things", "report_inbox" => inbox, "tag" => "count"}
      }

      :ok =
        Custode.OneShotJob.handle_result(
          structured_result(%{"directive" => "none", "summary" => "42 things"}, cost_usd: 0.02),
          job
        )

      note = File.read!(Path.join(inbox, "job-991-count.md"))
      assert note =~ "job #991"
      assert note =~ "42 things"
    end

    test "handle_error writes a failure note and keeps the verdict" do
      inbox = Path.join(tmp_workspace!(), "inbox")
      job = %Oban.Job{id: 992, args: %{"prompt" => "x", "report_inbox" => inbox}}

      assert {:cancel, :auth} =
               Custode.OneShotJob.handle_error({:cancel, :auth}, error(:auth), job)

      assert File.read!(Path.join(inbox, "job-992-job.md")) =~ "FAILED"
    end
  end
end
