defmodule Custode.OperatorToolsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Gates.{Gate, Review}
  alias Custode.MCP.OperatorTools
  alias Custode.MCP.OwnedCheckoutTools
  alias Custode.{OperationCall, OperationRegistry, Repo}
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

      assert_receive {:enqueued, _args, %{"agent_id" => ^id} = turn_meta}

      :ok =
        finish_agent_turn(
          turn_meta,
          structured_result(%{"directive" => "request_permission", "action" => "rm -rf"})
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

    test "returns the review attached to a gate" do
      repo = "acme/#{uid("reviewed")}"

      review =
        %Review{}
        |> Review.changeset(%{
          repo: repo,
          pr_number: 7,
          head_sha: "head-7",
          author_provider: "claude",
          reviewer_provider: "codex",
          round: 1,
          status: "completed"
        })
        |> Repo.insert!()
        |> Ecto.Changeset.change(
          summary: "one warning",
          findings: Jason.encode!([%{"severity" => "WARN", "claim" => "missing test"}])
        )
        |> Repo.update!()

      gate =
        Repo.insert!(%Gate{
          agent_id: uid("review-gate"),
          kind: "approval",
          action_id: uid("act"),
          detail: "merge it",
          class: "merge",
          repo: repo,
          pr_number: 7,
          review_id: review.id,
          review_state: "completed"
        })

      on_exit(fn ->
        Repo.delete_all(from(g in Gate, where: g.id == ^gate.id))
        Repo.delete_all(from(r in Review, where: r.id == ^review.id))
      end)

      json = tool_json(OperatorTools.ListGates.execute(%{status: "open"}, @frame))
      assert row = Enum.find(json["gates"], &(&1["action_id"] == gate.action_id))
      assert row["review_state"] == "completed"
      assert row["review"]["provider"] == "codex"
      assert row["review"]["findings"] == [%{"severity" => "WARN", "claim" => "missing test"}]
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
    test "projects the registered fleet.pause_agent definition" do
      assert {:ok, definition} =
               OperationRegistry.fetch(OperationRegistry.default(), "fleet.pause_agent")

      assert OperatorTools.PauseAgent.definition() == definition
      assert OperatorTools.PauseAgent.name() == definition.projection.mcp.name
    end

    test "round-trips through paused" do
      id = start_stub_agent!()
      :ok = Custode.PubSubBridge.subscribe()

      json = tool_json(OperatorTools.PauseAgent.execute(%{agent_id: id}, @frame))
      assert json["state"] == "paused"
      {:ok, :paused} = Agent.await(id, :paused, 1_000)
      assert_receive {:status_changed, ^id}

      eventually(fn ->
        assert Enum.any?(Custode.Feed.for_agent(id), &(&1["event"] == "paused"))
      end)

      assert %OperationCall{
               operation: "fleet.pause_agent",
               actor: %{"kind" => "operator", "id" => "operator"},
               transport: "mcp",
               status: "succeeded"
             } =
               Repo.all(OperationCall)
               |> Enum.find(&(&1.arguments == %{"agent_id" => id}))

      json = tool_json(OperatorTools.ResumeAgent.execute(%{agent_id: id}, @frame))
      assert json["state"] == "resumed"
      {:ok, :idle} = Agent.await(id, :idle, 1_000)
    end

    test "duplicate MCP submissions replay one logical result" do
      id = start_stub_agent!()
      key = "mcp-#{System.unique_integer([:positive])}"
      params = %{agent_id: id, idempotency_key: key}

      first = tool_json(OperatorTools.PauseAgent.execute(params, @frame))
      second = tool_json(OperatorTools.PauseAgent.execute(params, @frame))

      assert first == second

      eventually(fn ->
        paused =
          Custode.Feed.for_agent(id)
          |> Enum.count(&(&1["event"] == "paused"))

        assert paused == 1
      end)

      assert Repo.aggregate(
               from(c in OperationCall, where: c.idempotency_key == ^key),
               :count
             ) == 1
    end

    test "a specialist routine cannot acquire pause authority through the tool", %{
      routine: routine
    } do
      id = start_stub_agent!()
      frame = frame_for(:routine, routine.id)

      assert tool_error(OperatorTools.PauseAgent.execute(%{agent_id: id}, frame)) =~
               "operator_required"

      assert {:ok, :idle} = Agent.status(id)

      assert %OperationCall{
               status: "denied",
               actor: %{"kind" => "routine", "id" => caller_id}
             } =
               Repo.all(OperationCall)
               |> Enum.find(&(&1.arguments == %{"agent_id" => id}))

      assert caller_id == routine.id
    end

    test "the existing caretaker grant remains authorized", %{workspace: workspace} do
      caretaker = routine_fixture!(workspace, %{role: :caretaker})
      id = start_stub_agent!()

      assert %{"agent_id" => ^id, "state" => "paused"} =
               OperatorTools.PauseAgent.execute(
                 %{agent_id: id},
                 frame_for(:routine, caretaker.id)
               )
               |> tool_json()

      assert %OperationCall{
               grant: "operator",
               actor: %{"kind" => "routine", "id" => caller_id}
             } =
               Repo.all(OperationCall)
               |> Enum.find(&(&1.arguments == %{"agent_id" => id}))

      assert caller_id == caretaker.id
    end

    test "pause of an offline agent is a tool error" do
      assert tool_error(OperatorTools.PauseAgent.execute(%{agent_id: "ghost"}, @frame)) =~ "pause"
    end
  end

  describe "owned checkout operations" do
    setup do
      home = tmp_workspace!()
      previous = System.get_env("CUSTODE_HOME")
      System.put_env("CUSTODE_HOME", home)

      on_exit(fn ->
        if previous,
          do: System.put_env("CUSTODE_HOME", previous),
          else: System.delete_env("CUSTODE_HOME")
      end)

      %{home: home}
    end

    test "projects both registered operation definitions" do
      registry = OperationRegistry.default()

      assert {:ok, provision} =
               OperationRegistry.fetch(registry, "fleet.provision_owned_checkout")

      assert {:ok, refresh} = OperationRegistry.fetch(registry, "fleet.refresh_owned_checkout")
      assert OwnedCheckoutTools.Provision.definition() == provision
      assert OwnedCheckoutTools.Provision.name() == "provision_owned_checkout"
      assert OwnedCheckoutTools.Refresh.definition() == refresh
      assert OwnedCheckoutTools.Refresh.name() == "refresh_owned_checkout"
    end

    test "dry-run provision names the deterministic filesystem effect", %{home: home} do
      json =
        OwnedCheckoutTools.Provision.execute(
          %{routine_id: "future-worker", repository: "acme/widgets", dry_run: true},
          @frame
        )
        |> tool_json()

      assert json["status"] == "dry_run"
      assert json["effect_preview"]["path"] == Path.join([home, "checkouts", "future-worker"])
      assert json["effect_preview"]["may"] == ["clone"]
      refute File.exists?(json["effect_preview"]["path"])
    end

    test "matching checkout is idempotent through MCP and records one call", %{home: home} do
      path = Path.join([home, "checkouts", "matching"])
      File.mkdir_p!(path)
      assert {_output, 0} = System.cmd("git", ["init", path])

      assert {_output, 0} =
               System.cmd("git", [
                 "-C",
                 path,
                 "remote",
                 "add",
                 "origin",
                 "git@github.com:acme/widgets.git"
               ])

      params = %{
        routine_id: "matching",
        repository: "acme/widgets",
        idempotency_key: "owned-matching"
      }

      first = tool_json(OwnedCheckoutTools.Provision.execute(params, @frame))
      second = tool_json(OwnedCheckoutTools.Provision.execute(params, @frame))
      assert first == second
      assert first["status"] == "already_provisioned"

      assert Repo.aggregate(
               from(c in OperationCall,
                 where:
                   c.operation == "fleet.provision_owned_checkout" and
                     c.idempotency_key == "owned-matching"
               ),
               :count
             ) == 1
    end

    test "refresh preview refuses a routine using an existing checkout", %{workspace: workspace} do
      routine = routine_fixture!(workspace, %{repo: "acme/widgets"})

      assert tool_error(
               OwnedCheckoutTools.Refresh.execute(
                 %{routine_id: routine.id, dry_run: true},
                 @frame
               )
             ) =~ "existing_checkout_refused"
    end

    test "specialist routines cannot acquire checkout authority", %{routine: routine} do
      frame = frame_for(:routine, routine.id)

      assert tool_error(
               OwnedCheckoutTools.Provision.execute(
                 %{routine_id: "future", repository: "acme/widgets"},
                 frame
               )
             ) =~ "operator_required"
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

    # the caretaker read $0.00 for the whole fleet 47 seconds after LOCAL
    # midnight and asked whether the ledger was broken: the tool said "UTC"
    test "says which window it counted: local midnight, not UTC" do
      put_env!(:timezone, "America/Los_Angeles")

      json = tool_json(OperatorTools.SpendToday.execute(%{}, @frame))

      assert json["timezone"] == "America/Los_Angeles"
      {:ok, since, 0} = DateTime.from_iso8601(json["since"])
      local = DateTime.shift_zone!(since, "America/Los_Angeles")
      assert {local.hour, local.minute, local.second} == {0, 0, 0}
      assert DateTime.compare(since, DateTime.utc_now()) == :lt
    end
  end

  defp frame_for(kind, id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}
end
