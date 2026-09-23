defmodule Custode.MCPToolsTest do
  # Tool handlers called directly with params + a bare Frame; the HTTP
  # transport is exercised separately.
  # Queues never execute in test, so "started" sub-agents insert real rows in
  # oban_jobs that never run -- the full plumbing, zero claude.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.MCP.{MCPEx, Tools}
  alias ObanClaude.Agent

  @frame %Anubis.Server.Frame{}

  describe "server boot" do
    test "the bounded mcp_ex request executor is running" do
      executor = Process.whereis(MCPEx.executor())
      assert is_pid(executor)
      assert Process.alive?(executor)
    end
  end

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
      # the memory-only endpoint (per-sub identity config), never the full toolbox
      assert job.args["mcp_config"] == [Custode.MCP.sub_agent_config_path(id)]
      assert job.args["allowed_tools"] == ["mcp__memory"]
    end

    test "a missing workspace is a tool error, not a crash" do
      reply = Tools.StartAgent.execute(%{agent_id: "x", workspace: "/nope/nothing"}, @frame)
      assert tool_error(reply) =~ "not an existing directory"
    end

    # "delivered: true" used to be the reply for a prompt the engine had
    # dropped (#472)
    test "the operator's prompt reaches a PAUSED agent, and the reply says it was resumed" do
      id = start_stub_agent!()
      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      json = tool_json(Tools.PromptAgent.execute(%{agent_id: id, prompt: "carry on"}, @frame))

      assert json["delivered"] == true
      assert json["how"] == "resumed"
      assert_receive {:enqueued, args, _meta}, 1_000
      assert args["prompt"] =~ "carry on"
    end

    test "the operator's prompt starts an OFFLINE routine with the prompt as its turn" do
      routine = routine_fixture!(tmp_workspace!())

      json =
        tool_json(
          Tools.PromptAgent.execute(%{agent_id: routine.id, prompt: "look at 42"}, @frame)
        )

      assert json["how"] == "started"

      assert [tick] =
               jobs_for("ObanClaude.Agent.Tick")
               |> Enum.filter(&(&1.args["agent_id"] == routine.id))

      assert tick.args["prompt"] == "look at 42"
    end

    test "a routine prompting its sub-agent keeps the direct cast and never resumes it" do
      id = start_stub_agent!()
      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      parent = %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: "boss"}}}
      :ok = Custode.SubAgents.record_spawn!(id, "boss", %{workspace: "/tmp"})
      on_exit(fn -> Custode.SubAgents.forget(id) end)
      json = tool_json(Tools.PromptAgent.execute(%{agent_id: id, prompt: "go"}, parent))

      assert json["how"] == "delivered"
      # the operator's pause stands: a parent cannot lift it by prompting
      assert {:ok, :paused} = Agent.status(id)
      refute_receive {:enqueued, _args, _meta}, 200
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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok = finish_agent_turn(turn_meta, result("all wrapped up"))

      json = tool_json(Tools.AwaitAgent.execute(%{agent_id: id, timeout_ms: 2_000}, @frame))
      assert json["state"] == "idle"
      assert json["timed_out"] == false
      assert json["last_result"] == "all wrapped up"
    end

    test "await surfaces a gated state atomically with its payload" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "x")

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "deploy"})
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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok = finish_agent_turn(turn_meta, result("done one"))
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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "risky"})
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

  describe "notebook and memory tools" do
    alias Custode.MCP.MemoryTools
    alias Custode.MCP.NotebookTools

    test "the sweep loop: inbox_list -> journal_append + todo_add -> inbox_mark_filed" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      File.write!(Path.join([workspace, "inbox", "note.md"]), "rotate the api key\n")

      json = tool_json(NotebookTools.InboxList.execute(%{routine_id: routine.id}, @frame))
      assert [%{"name" => "note.md", "content" => "rotate the api key\n"}] = json["notes"]

      json =
        tool_json(
          NotebookTools.JournalAppend.execute(
            %{routine_id: routine.id, body: "note about key rotation", title: "keys"},
            @frame
          )
        )

      assert is_integer(json["entry_id"])

      json =
        tool_json(
          NotebookTools.TodoAdd.execute(%{routine_id: routine.id, text: "rotate key"}, @frame)
        )

      todo_id = json["todo_id"]

      json =
        tool_json(
          NotebookTools.InboxMarkFiled.execute(%{routine_id: routine.id, name: "note.md"}, @frame)
        )

      assert json["filed"] == "note.md"

      assert tool_json(NotebookTools.InboxList.execute(%{routine_id: routine.id}, @frame)) ==
               %{"notes" => []}

      json = tool_json(NotebookTools.TodoList.execute(%{routine_id: routine.id}, @frame))
      assert [%{"id" => ^todo_id, "status" => "open"}] = json["todos"]

      json = tool_json(NotebookTools.TodoComplete.execute(%{todo_id: todo_id}, @frame))
      assert json["status"] == "done"

      # and the rendered views followed along
      assert File.read!(Path.join(workspace, "journal.md")) =~ "keys"
      assert File.read!(Path.join(workspace, "TODO.md")) =~ "- [x]"
    end

    test "notebook tool error paths" do
      routine = routine_fixture!(tmp_workspace!())

      assert tool_error(NotebookTools.InboxList.execute(%{routine_id: "ghost"}, @frame)) =~
               "unknown routine"

      assert tool_error(
               NotebookTools.InboxMarkFiled.execute(
                 %{routine_id: routine.id, name: "../escape.md"},
                 @frame
               )
             ) =~ "must not be a path"

      assert tool_error(NotebookTools.TodoComplete.execute(%{todo_id: 999_999}, @frame)) =~
               "no todo"

      assert tool_error(
               NotebookTools.TodoList.execute(%{routine_id: routine.id, status: "wat"}, @frame)
             ) =~ "unknown status"
    end

    test "remember / recall / forget round trip" do
      id = uid("mem")

      json =
        tool_json(
          MemoryTools.Remember.execute(%{agent_id: id, key: "pref", value: "be brief"}, @frame)
        )

      assert json["remembered"] == "pref"

      json = tool_json(MemoryTools.Recall.execute(%{agent_id: id, key: "pref"}, @frame))
      assert json["value"] == "be brief"

      json = tool_json(MemoryTools.Recall.execute(%{agent_id: id}, @frame))
      assert [%{"key" => "pref", "value" => "be brief"}] = json["memories"]

      assert tool_error(MemoryTools.Recall.execute(%{agent_id: id, key: "nope"}, @frame)) =~
               "nothing remembered"

      json = tool_json(MemoryTools.Forget.execute(%{agent_id: id, key: "pref"}, @frame))
      assert json["forgot"] == "pref"
      assert tool_json(MemoryTools.Recall.execute(%{agent_id: id}, @frame)) == %{"memories" => []}
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

    test "elevated jobs run bypass_permissions; default jobs stay edit-only" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      json =
        tool_json(Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox}, @frame))

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["permission_mode"] == "accept_edits"
      assert job.args["timeout"] == 200_000

      json =
        tool_json(
          Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, elevated: true}, @frame)
        )

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["permission_mode"] == "bypass_permissions"
      assert job.args["timeout"] == 900_000
    end

    test "the dispatcher can size the job's spend cap" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      json =
        tool_json(
          Tools.RunJob.execute(
            %{prompt: "x", report_inbox: inbox, elevated: true, max_budget_usd: 3.0},
            @frame
          )
        )

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["max_budget_usd"] == 3.0
    end

    test "a missing report_inbox directory is a tool error" do
      reply = Tools.RunJob.execute(%{prompt: "x", report_inbox: "/nope/inbox"}, @frame)
      assert tool_error(reply) =~ "report_inbox"
    end

    test "a routine defaults to its configured checkout and reports to its own inbox" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace, %{working_dir: workspace})
      frame = routine_frame(routine.id)

      json =
        tool_json(
          Tools.RunJob.execute(
            %{prompt: "inspect it", report_inbox: Path.join(workspace, "inbox")},
            frame
          )
        )

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert File.stat!(job.args["working_dir"]) == File.stat!(workspace)

      assert File.stat!(job.args["report_inbox"]) ==
               File.stat!(Path.join(workspace, "inbox"))
    end

    test "a routine may use its owned checkout" do
      notebook = tmp_workspace!()
      routine = routine_fixture!(notebook)
      {:ok, owned} = Custode.OwnedCheckout.path(routine.id)
      File.mkdir_p!(owned)
      on_exit(fn -> File.rm_rf!(owned) end)

      json =
        tool_json(
          Tools.RunJob.execute(
            %{
              prompt: "inspect it",
              workspace: owned,
              report_inbox: Path.join(notebook, "inbox")
            },
            routine_frame(routine.id)
          )
        )

      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["working_dir"] == owned
    end

    test "a routine cannot traverse out or use another routine's checkout or inbox" do
      own = tmp_workspace!()
      sibling = tmp_workspace!()
      id = uid("job-owner")
      sibling_id = uid("job-sibling")

      put_env!(:routines, [
        %{id: id, cron: :manual, workspace: own, working_dir: own, prompt: "x"},
        %{
          id: sibling_id,
          cron: :manual,
          workspace: sibling,
          working_dir: sibling,
          prompt: "x"
        }
      ])

      frame = routine_frame(id)
      inbox = Path.join(own, "inbox")
      before = length(jobs_for("Custode.OneShotJob"))
      symlink = Path.join(own, "sibling-link")
      File.ln_s!(sibling, symlink)

      traversal = Path.join([own, "..", Path.basename(sibling)])

      assert tool_error(
               Tools.RunJob.execute(
                 %{prompt: "x", workspace: traversal, report_inbox: inbox},
                 frame
               )
             ) =~ "may not use workspace"

      assert tool_error(
               Tools.RunJob.execute(
                 %{prompt: "x", workspace: symlink, report_inbox: inbox},
                 frame
               )
             ) =~ "may not use workspace"

      assert tool_error(
               Tools.RunJob.execute(
                 %{prompt: "x", workspace: sibling, report_inbox: inbox},
                 frame
               )
             ) =~ "may not use workspace"

      assert tool_error(
               Tools.RunJob.execute(
                 %{prompt: "x", workspace: own, report_inbox: Path.join(sibling, "inbox")},
                 frame
               )
             ) =~ "may not use report_inbox"

      assert length(jobs_for("Custode.OneShotJob")) == before
    end

    test "elevated routine jobs require a live shell approval" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      frame = routine_frame(routine.id)
      args = %{prompt: "x", report_inbox: Path.join(workspace, "inbox"), elevated: true}
      before = length(jobs_for("Custode.OneShotJob"))

      assert tool_error(Tools.RunJob.execute(args, frame)) =~
               "elevated job with no approved action"

      refute_job_inserted(before)
      gate = approved_gate!(routine.id, "comment")

      assert tool_error(Tools.RunJob.execute(args, frame)) =~ "outside gate #{gate.id}"
      refute_job_inserted(before)

      Custode.Repo.delete!(gate)
      _gate = approved_gate!(routine.id, "implement")
      json = tool_json(Tools.RunJob.execute(args, frame))
      assert is_integer(json["job_id"])
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

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  defp approved_gate!(agent_id, class) do
    gate =
      Custode.Repo.insert!(%Custode.Gates.Gate{
        agent_id: agent_id,
        kind: "approval",
        status: "resolved",
        outcome: "approved",
        class: class
      })

    on_exit(fn ->
      if Custode.Repo.get(Custode.Gates.Gate, gate.id), do: Custode.Repo.delete!(gate)
    end)

    gate
  end

  defp refute_job_inserted(before) do
    assert length(jobs_for("Custode.OneShotJob")) == before
  end
end
