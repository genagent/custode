defmodule Custode.MCPToolsTest do
  # Tool handlers called directly with params + a bare Frame; the HTTP
  # transport is exercised separately.
  # Queues never execute in test, so "started" sub-agents insert real rows in
  # oban_jobs that never run -- the full plumbing, zero claude.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import ObanClaude.Testing

  alias Custode.MCP.{MCPEx, ReadTools, Scope, Tools}
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

    test "agent_status exposes the same durable conversation model while offline" do
      routine = routine_fixture!(tmp_workspace!())
      assert {:ok, prepared} = Custode.ConversationArcs.prepare(routine, :operator)

      json = tool_json(Tools.AgentStatus.execute(%{agent_id: routine.id}, @frame))

      assert json["state"] == "offline"
      assert json["conversation"]["current"]["arc_id"] == prepared.arc_id
      assert json["conversation"]["current"]["logical_id"] == "operator"
      assert json["conversation"]["current"]["decision"] == "fresh"
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
      assert json["message_id"] =~ "msg_"
      assert json["status"] in ["queued", "executing"]
      assert json["duplicate"] == false
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

      assert [turn] =
               jobs_for("ObanClaude.Agent.Job")
               |> Enum.filter(&(&1.meta["agent_id"] == routine.id))

      assert turn.args["prompt"] == "look at 42"
      assert turn.meta["arc_id"] =~ "operator:"
    end

    test "a routine prompting its paused sub-agent receives a durable refusal" do
      id = start_stub_agent!()
      :ok = Agent.emergency_pause(id)
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      parent = %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: "boss"}}}
      :ok = Custode.SubAgents.record_spawn!(id, "boss", %{workspace: "/tmp"})
      on_exit(fn -> Custode.SubAgents.forget(id) end)
      json = tool_json(Tools.PromptAgent.execute(%{agent_id: id, prompt: "go"}, parent))

      assert json["delivered"] == false
      assert json["status"] == "refused"
      assert json["error"]["detail"] =~ "agent_paused"
      # the operator's pause stands: a parent cannot lift it by prompting
      assert {:ok, :paused} = Agent.status(id)
      refute_receive {:enqueued, _args, _meta}, 200
    end

    test "an idempotency retry returns the same receipt without a second delivery" do
      id = start_stub_agent!()

      params = %{agent_id: id, prompt: "release it", idempotency_key: "release-42"}
      first = tool_json(Tools.PromptAgent.execute(params, @frame))
      assert_receive {:enqueued, _args, _meta}

      second = tool_json(Tools.PromptAgent.execute(params, @frame))
      assert second["message_id"] == first["message_id"]
      assert second["duplicate"] == true
      refute_receive {:enqueued, _args, _meta}, 100

      reply =
        Tools.PromptAgent.execute(
          %{params | prompt: "change it after all"},
          @frame
        )

      assert tool_error(reply) =~ "idempotency_conflict"
    end

    test "failure before enqueue returns a durable refused receipt" do
      json = tool_json(Tools.PromptAgent.execute(%{agent_id: "ghost", prompt: "x"}, @frame))

      assert json["delivered"] == false
      assert json["status"] == "refused"
      assert json["error"]["kind"] == "delivery_refused"
      assert json["message_id"] =~ "msg_"
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

    test "message_id awaits the exact prompt and returns its provider identity" do
      id = start_stub_agent!()

      prompt = tool_json(Tools.PromptAgent.execute(%{agent_id: id, prompt: "exact"}, @frame))
      assert_receive {:enqueued, _args, turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          result(result: "exact result", session_id: "exact-session")
        )

      json =
        tool_json(
          Tools.AwaitAgent.execute(
            %{agent_id: id, message_id: prompt["message_id"], timeout_ms: 2_000},
            @frame
          )
        )

      assert json["message_id"] == prompt["message_id"]
      assert json["status"] == "completed"
      assert json["timed_out"] == false
      assert json["provider_turn"]["generation"] == turn_meta["agent_generation"]
      assert json["provider_turn"]["turn_id"] == turn_meta["agent_turn_id"]
      assert json["provider_turn"]["arc_id"] == turn_meta["arc_id"]
      assert json["provider_turn"]["session_id"] == "exact-session"
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

      retry =
        tool_json(Tools.ApproveAction.execute(%{agent_id: id, action_id: action_id}, @frame))

      assert retry == %{
               "agent_id" => id,
               "approved" => action_id,
               "already_applied" => true
             }

      refute_receive {:enqueued, _args, _meta}, 50
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

      retry =
        tool_json(
          Tools.RejectAction.execute(%{agent_id: id, action_id: action_id, reason: "no"}, @frame)
        )

      assert retry == %{
               "agent_id" => id,
               "rejected" => action_id,
               "already_applied" => true
             }
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

    test "an omitted max_turns keeps the default and the reply names it" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      json = tool_json(Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox}, @frame))

      assert json["max_turns"] == 15
      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["max_turns"] == 15
    end

    test "the operator may set a bounded max_turns that reaches the job" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      json =
        tool_json(
          Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 75}, @frame)
        )

      assert json["max_turns"] == 75
      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["max_turns"] == 75
    end

    test "invalid, zero and over-ceiling max_turns are typed errors that insert nothing" do
      inbox = Path.join(tmp_workspace!(), "inbox")
      before = length(jobs_for("Custode.OneShotJob"))
      ceiling = Scope.job_turns_ceiling()

      for bad <- [0, -3, 2.5, "40"] do
        assert tool_error(
                 Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: bad}, @frame)
               ) =~ "max_turns: must be a positive integer"
      end

      assert tool_error(
               Tools.RunJob.execute(
                 %{prompt: "x", report_inbox: inbox, max_turns: ceiling + 1},
                 @frame
               )
             ) =~ "exceeds the hard ceiling of #{ceiling}"

      refute_job_inserted(before)
    end

    test "a routine may lower max_turns but raising it needs an approved action" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      frame = routine_frame(routine.id)
      inbox = Path.join(workspace, "inbox")
      before = length(jobs_for("Custode.OneShotJob"))

      assert tool_error(
               Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 75}, frame)
             ) =~ "max_turns 75 is above the default of 15 with no approved action"

      refute_job_inserted(before)

      json =
        tool_json(Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 5}, frame))

      assert json["max_turns"] == 5
    end

    test "an unrelated active grant cannot raise max_turns" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      frame = routine_frame(routine.id)
      inbox = Path.join(workspace, "inbox")

      for class <- ["comment", "ready_pr"] do
        gate = approved_gate!(routine.id, class)
        before = length(jobs_for("Custode.OneShotJob"))

        assert tool_error(
                 Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 150}, frame)
               ) =~ "outside gate #{gate.id} (class #{class})"

        refute_job_inserted(before)

        json =
          tool_json(
            Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 15}, frame)
          )

        assert json["max_turns"] == 15
        Custode.Repo.delete!(gate)
      end
    end

    test "an approved specialist job may exceed the routine's own sweep cap" do
      workspace = tmp_workspace!()
      id = uid("job-specialist")

      put_env!(:routines, [
        %{
          id: id,
          cron: :manual,
          workspace: workspace,
          working_dir: workspace,
          prompt: "x",
          max_turns: 20
        }
      ])

      frame = routine_frame(id)
      _gate = approved_gate!(id, "implement", "fix #1: implement the slice; max_turns=75")

      args = %{
        prompt: "implement the approved slice",
        report_inbox: Path.join(workspace, "inbox"),
        elevated: true,
        max_budget_usd: 12,
        max_turns: 75
      }

      json = tool_json(Tools.RunJob.execute(args, frame))

      assert json["max_turns"] == 75
      [job] = jobs_for("Custode.OneShotJob") |> Enum.filter(&(&1.id == json["job_id"]))
      assert job.args["max_turns"] == 75
      assert job.args["permission_mode"] == "bypass_permissions"

      assert tool_error(
               Tools.RunJob.execute(
                 %{args | max_turns: Scope.job_turns_ceiling() + 1},
                 frame
               )
             ) =~ "exceeds the hard ceiling"
    end

    test "a routine's raise must match the max_turns=<N> its shell-class gate approved" do
      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      frame = routine_frame(routine.id)
      inbox = Path.join(workspace, "inbox")

      run = fn turns ->
        Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: turns}, frame)
      end

      # exact: the approved cap itself, and anything between it and the default
      gate = approved_gate!(routine.id, "implement", "fix #9: slice one; max_turns=60; draft PR")
      assert tool_json(run.(60))["max_turns"] == 60
      assert tool_json(run.(40))["max_turns"] == 40

      # too low an approval: the request is above the approved cap
      before = length(jobs_for("Custode.OneShotJob"))
      assert tool_error(run.(61)) =~ "max_turns 61 exceeds the max_turns=60 that gate #{gate.id}"
      refute_job_inserted(before)
      Custode.Repo.delete!(gate)

      # missing: a shell-class approval that never named a cap
      gate = approved_gate!(routine.id, "pr_maintain", "fix CI on #9; push to the same branch")
      assert tool_error(run.(40)) =~ "gate #{gate.id} names no max_turns=<N>"
      refute_job_inserted(before)
      # the default and below still need no marker
      assert tool_json(run.(15))["max_turns"] == 15
      Custode.Repo.delete!(gate)

      # ambiguous: two different caps match no single approval
      gate = approved_gate!(routine.id, "implement", "max_turns=40 then max_turns=90")
      before = length(jobs_for("Custode.OneShotJob"))
      assert tool_error(run.(30)) =~ "gate #{gate.id} names more than one max_turns=<N>"
      refute_job_inserted(before)
    end

    test "approved_turn_cap reads exactly one stable marker" do
      assert Scope.approved_turn_cap("implement #1; max_turns=75") == {:ok, 75}
      assert Scope.approved_turn_cap("max_turns=75 ... max_turns=75") == {:ok, 75}
      assert Scope.approved_turn_cap("max_turns=40, max_turns=75") == :ambiguous
      assert Scope.approved_turn_cap("raise max_turns to 75") == :missing
      assert Scope.approved_turn_cap("run_job_max_turns=75") == :missing
      assert Scope.approved_turn_cap("max_turns=75x") == :missing
      assert Scope.approved_turn_cap("max_turns=0") == :missing
      assert Scope.approved_turn_cap(nil) == :missing
    end

    test "invalid configured bounds are typed errors that insert nothing" do
      inbox = Path.join(tmp_workspace!(), "inbox")
      before = length(jobs_for("Custode.OneShotJob"))

      cases = [
        {15, 0, "run_job_max_turns_ceiling must be a positive integer"},
        {15, "150", "run_job_max_turns_ceiling must be a positive integer"},
        {0, 150, "run_job_max_turns must be a positive integer"},
        {nil, 150, "run_job_max_turns must be a positive integer"},
        {2.5, 150, "run_job_max_turns must be a positive integer"},
        {200, 150, "run_job_max_turns 200 exceeds run_job_max_turns_ceiling 150"}
      ]

      for {default, ceiling, message} <- cases do
        put_env!(:run_job_max_turns, default)
        put_env!(:run_job_max_turns_ceiling, ceiling)

        # omission is checked too, and so is an explicit value
        assert tool_error(Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox}, @frame)) =~
                 message

        assert tool_error(
                 Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 5}, @frame)
               ) =~ message
      end

      refute_job_inserted(before)
    end

    test "a running one-shot job shows its turn cap in executing_turns" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      json =
        tool_json(
          Tools.RunJob.execute(%{prompt: "x", report_inbox: inbox, max_turns: 40}, @frame)
        )

      other =
        Custode.Repo.insert!(%Oban.Job{
          worker: "Custode.NotAJob",
          queue: "agents",
          args: %{"max_turns" => 99},
          state: "executing"
        })

      ids = [json["job_id"], other.id]

      on_exit(fn -> Custode.Repo.delete_all(from(j in Oban.Job, where: j.id in ^ids)) end)

      Custode.Repo.update_all(from(j in Oban.Job, where: j.id == ^json["job_id"]),
        set: [state: "executing"]
      )

      executing = Custode.executing_turns()
      assert %{worker: "Custode.OneShotJob", max_turns: 40} = find_job(executing, json["job_id"])
      refute Map.has_key?(find_job(executing, other.id), :max_turns)
      refute Map.has_key?(find_job(executing, other.id), :args)

      reply = tool_json(ReadTools.ExecutingTurns.execute(%{}, @frame))
      assert Enum.find(reply["executing"], &(&1["id"] == json["job_id"]))["max_turns"] == 40
    end

    test "the completion report carries the resolved turn cap" do
      inbox = Path.join(tmp_workspace!(), "inbox")

      job = %Oban.Job{
        id: 993,
        args: %{
          "prompt" => "long work",
          "report_inbox" => inbox,
          "tag" => "long",
          "max_turns" => 75
        }
      }

      Custode.OneShotJob.handle_error(
        {:cancel, :max_turns_exceeded},
        error(:max_turns_exceeded),
        job
      )

      note = File.read!(Path.join(inbox, "job-993-long.md"))
      assert note =~ ~s("max_turns":75)
      assert note =~ "Turn cap: 75."
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

  defp approved_gate!(agent_id, class, detail \\ nil) do
    gate =
      Custode.Repo.insert!(%Custode.Gates.Gate{
        agent_id: agent_id,
        kind: "approval",
        status: "resolved",
        outcome: "approved",
        class: class,
        detail: detail
      })

    on_exit(fn ->
      if Custode.Repo.get(Custode.Gates.Gate, gate.id), do: Custode.Repo.delete!(gate)
    end)

    gate
  end

  defp find_job(jobs, id), do: Enum.find(jobs, &(&1.id == id))

  defp refute_job_inserted(before) do
    assert length(jobs_for("Custode.OneShotJob")) == before
  end
end
