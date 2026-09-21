defmodule Custode.MCP.ReadToolsTest do
  @moduledoc """
  Tier 1 of #345: the reads that existed as functions and could not be
  reached by any MCP client.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.ReadTools

  @frame %Anubis.Server.Frame{}

  setup do
    path = Path.join(System.tmp_dir!(), uid("read") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    # these tests assert on the whole fleet's attention, so every source of a
    # signal has to be this module's own (see clear_attention!/0)
    clean = fn ->
      Custode.Repo.query!("DELETE FROM feed_entries")
      clear_attention!()
    end

    clean.()
    on_exit(clean)

    %{workspace: tmp_workspace!()}
  end

  describe "list_attention" do
    test "answers what needs a human, grouped and ranked", %{workspace: workspace} do
      routine = routine_fixture!(workspace)
      {:ok, _ask} = Custode.Asks.ask(routine.id, "which env?")

      json = ReadTools.Attention.execute(%{}, @frame) |> tool_json()

      needs_you = Enum.find(json["groups"], &(&1["group"] == "needs_you"))
      assert [signal] = needs_you["signals"]
      assert signal["subject"] == routine.id
      assert signal["headline"] == "asked you a question"
      # the resolving list rides along, so a client can render actions
      assert [%{"op" => "answer_ask"} | _rest] = signal["resolving"]
    end

    test "filters to one group", %{workspace: workspace} do
      _routine = routine_fixture!(workspace)

      json = ReadTools.Attention.execute(%{group: "needs_you"}, @frame) |> tool_json()

      assert Enum.all?(json["groups"], &(&1["group"] == "needs_you"))
    end
  end

  describe "list_inbox" do
    test "is the OPERATOR's inbox, not an agent's notes", %{workspace: workspace} do
      routine = routine_fixture!(workspace)
      {:ok, _ask} = Custode.Asks.ask(routine.id, "which env?")

      json = ReadTools.Inbox.execute(%{}, @frame) |> tool_json()

      assert [item] = json["items"]
      assert item["subject"] == routine.id
      assert item["headline"] == "asked you a question"
    end
  end

  describe "list_roles" do
    test "exposes the permission model that was readable only from inside" do
      json = ReadTools.Roles.execute(%{}, @frame) |> tool_json()

      caretaker = Enum.find(json["roles"], &(&1["role"] == "caretaker"))
      assert caretaker["tier"] == "custode"
      assert caretaker["grants"] == "operator"
      assert "operator" in json["tiers"]
    end
  end

  describe "metrics" do
    test "gate_latency returns a named JSON object and does not apply the days window" do
      agent = uid("latency")
      old = DateTime.add(DateTime.utc_now(), -10, :day)

      gate =
        Custode.Repo.insert!(%Custode.Gates.Gate{
          agent_id: agent,
          kind: "approval",
          action_id: uid("action"),
          detail: "ship the bounded change",
          status: "resolved",
          inserted_at: old,
          updated_at: old
        })

      json = ReadTools.Metrics.execute(%{kind: "gate_latency", days: 1}, @frame) |> tool_json()

      assert json["kind"] == "gate_latency"
      assert json["days"] == 1
      assert is_integer(json["data"]["median_minutes"])
      assert item = Enum.find(json["data"]["gates"], &(&1["agent"] == agent))
      assert item["detail"] == "ship the bounded change"

      Custode.Repo.delete!(gate)

      empty = ReadTools.Metrics.execute(%{kind: "gate_latency", days: 30}, @frame) |> tool_json()
      assert empty["data"] == %{"gates" => [], "median_minutes" => 0}
    end

    test "prs_opened flattens its tuples rather than failing at encode" do
      json = ReadTools.Metrics.execute(%{kind: "prs_opened", days: 7}, @frame) |> tool_json()
      assert is_map(json["data"])
    end

    test "one tool, several kinds" do
      json = ReadTools.Metrics.execute(%{kind: "gate_outcomes", days: 7}, @frame) |> tool_json()

      assert json["kind"] == "gate_outcomes"
      assert json["days"] == 7
      assert is_map(json["data"])
    end

    test "an unknown kind is a tool error naming the known ones" do
      error = ReadTools.Metrics.execute(%{kind: "vibes"}, @frame) |> tool_error()

      assert error =~ "unknown metric vibes"
      assert error =~ "gate_outcomes"
    end
  end

  describe "the rest answer without arguments" do
    test "suggestions, outcomes, advisors, policies, workflows, executing" do
      for {module, key} <- [
            {ReadTools.Suggestions, "suggestions"},
            {ReadTools.SuggestionOutcomes, "decisions"},
            {ReadTools.Advisors, "advisors"},
            {ReadTools.Policies, "policies"},
            {ReadTools.Workflows, "workflows"},
            {ReadTools.ExecutingTurns, "executing"}
          ] do
        json = module.execute(%{}, @frame) |> tool_json()
        assert is_list(json[key]), "#{inspect(module)} did not answer with #{key}"
      end
    end

    test "policies flatten their keyword selectors" do
      json = ReadTools.Policies.execute(%{}, @frame) |> tool_json()
      assert is_list(json["policies"])
    end

    test "digest renders typed or as markdown" do
      typed = ReadTools.Digest.execute(%{days: 1}, @frame) |> tool_json()
      assert is_map(typed)

      rendered = ReadTools.Digest.execute(%{days: 1, markdown: true}, @frame) |> tool_json()
      assert is_binary(rendered["markdown"])
    end
  end

  describe "registering is not granting" do
    # The decision that makes tier 1 cheap: these are reachable by the CLI and
    # external clients, and are in NO agent's allowlist. Handing every sweep
    # eleven fleet-wide reads would be eleven new ways to spend itself.
    test "no read tool leaks into an agent allowlist", %{workspace: workspace} do
      routine = routine_fixture!(workspace)
      args = Custode.Routine.tick_args(Custode.Routine.get(routine.id))
      allowed = get_in(args, ["start", "args", :allowed_tools]) || []

      for tool <- ~w(list_attention list_inbox list_suggestions list_advisors
                     list_roles list_policies list_workflows metrics digest
                     list_suggestion_outcomes executing_turns) do
        refute "mcp__custode__#{tool}" in allowed
      end
    end
  end
end
