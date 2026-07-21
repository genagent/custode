defmodule Custode.OperatorToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.MCP.OperatorTools
  alias ObanClaude.Agent

  @frame %Anubis.Server.Frame{}

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{workspace: workspace, routine: routine}
  end

  describe "beat" do
    test "schedules a tick through the routine's own policy", %{routine: routine} do
      json = tool_json(OperatorTools.Beat.execute(%{agent_id: routine.id}, @frame))
      assert json["agent_id"] == routine.id

      assert [job] =
               jobs_for("ObanClaude.Agent.Tick")
               |> Enum.filter(&(&1.args["agent_id"] == routine.id))

      assert job.args["if_offline"] == "start"
      assert job.queue == "ticks"
    end

    test "refuses unknown routines" do
      assert tool_error(OperatorTools.Beat.execute(%{agent_id: "ghost"}, @frame)) =~
               "unknown routine"
    end
  end

  describe "drop_note" do
    test "writes the note and fires the event kickoff", %{workspace: workspace, routine: routine} do
      reply =
        OperatorTools.DropNote.execute(
          %{agent_id: routine.id, name: "ci.md", content: "PR red\n"},
          @frame
        )

      json = tool_json(reply)
      assert json["path"] == Path.join([workspace, "inbox", "ci.md"])
      assert File.read!(json["path"]) == "PR red\n"

      # the funnel scheduled the debounced beat
      assert Enum.any?(jobs_for("ObanClaude.Agent.Tick"), &(&1.args["agent_id"] == routine.id))
    end

    test "defaults the filename and refuses unknown routines", %{routine: routine} do
      json =
        tool_json(OperatorTools.DropNote.execute(%{agent_id: routine.id, content: "x"}, @frame))

      assert Path.basename(json["path"]) =~ ~r/^note-\d{8}-\d{6}\.md$/

      assert tool_error(
               OperatorTools.DropNote.execute(%{agent_id: "ghost", content: "x"}, @frame)
             ) =~
               "unknown_routine"
    end
  end

  describe "list_gates" do
    test "shows an open gate with the action id approve_action needs" do
      id = start_stub_agent!()
      :processing = Agent.submit_prompt(id, "go")

      :ok =
        Agent.job_finished(
          id,
          {:ok, structured_result(%{"directive" => "request_permission", "action" => "rm -rf"})}
        )

      {:ok, {:awaiting_permission, action}} = Agent.await(id, :awaiting_permission, 1_000)

      json = tool_json(OperatorTools.ListGates.execute(%{status: "open"}, @frame))
      assert gate = Enum.find(json["gates"], &(&1["agent_id"] == id))
      assert gate["action_id"] == action.id
      assert gate["detail"] =~ "rm -rf"

      # resolve and confirm the open filter no longer shows it
      :rejected = Agent.reject_action(id, action.id, "test")
      {:ok, :idle} = Agent.await(id, :idle, 1_000)
      json = tool_json(OperatorTools.ListGates.execute(%{status: "open"}, @frame))
      refute Enum.find(json["gates"], &(&1["agent_id"] == id))
    end
  end

  describe "feed_tail" do
    test "returns recent entries, optionally per agent" do
      first = uid("op-a")
      second = uid("op-b")
      Custode.Feed.record(%{agent: first, event: "turn", summary: "one"})
      Custode.Feed.record(%{agent: second, event: "turn", summary: "two"})

      json = tool_json(OperatorTools.FeedTail.execute(%{n: 500}, @frame))
      summaries = Enum.map(json["entries"], & &1["summary"])
      assert "one" in summaries
      assert "two" in summaries

      json = tool_json(OperatorTools.FeedTail.execute(%{agent_id: second}, @frame))
      assert [%{"summary" => "two"}] = json["entries"]
    end
  end

  describe "pause_agent / resume_agent" do
    test "round-trips through paused" do
      id = start_stub_agent!()

      json = tool_json(OperatorTools.PauseAgent.execute(%{agent_id: id}, @frame))
      assert json["state"] == "paused"
      {:ok, :paused} = Agent.await(id, :paused, 1_000)

      json = tool_json(OperatorTools.ResumeAgent.execute(%{agent_id: id}, @frame))
      assert json["state"] == "resumed"
      {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "pause of an offline agent is a tool error" do
      assert tool_error(OperatorTools.PauseAgent.execute(%{agent_id: "ghost"}, @frame)) =~ "pause"
    end
  end

  describe "spend_today" do
    test "reports per-routine spend with the daily rail and a fleet total",
         %{routine: routine} do
      :ok = Custode.SpendLedger.record(routine.id, 1.25)

      json = tool_json(OperatorTools.SpendToday.execute(%{}, @frame))
      assert row = Enum.find(json["routines"], &(&1["agent_id"] == routine.id))
      assert row["today_usd"] == 1.25
      assert row["daily_budget_usd"] == routine.daily_budget_usd
      assert json["fleet_today_usd"] >= 1.25
    end
  end
end
