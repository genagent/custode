defmodule Custode.RoutineTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  describe "normalize and defaults" do
    test "fills model, budget, system prompt, and mcp from the shared defaults" do
      routine = routine_fixture!("workspace")

      assert routine.model == Application.fetch_env!(:custode, :model)
      assert routine.max_budget_usd == Application.fetch_env!(:custode, :max_budget_usd)
      assert routine.system_prompt =~ "caretaker"
      assert routine.mcp == false
    end

    test "per-routine overrides win" do
      routine =
        routine_fixture!("workspace", %{
          model: "haiku",
          max_budget_usd: 0.1,
          system_prompt: "you are a test",
          mcp: true
        })

      assert routine.model == "haiku"
      assert routine.max_budget_usd == 0.1
      assert routine.system_prompt == "you are a test"
      assert routine.mcp == true
    end

    test "get/1 finds by id; default/0 is the first entry" do
      routine = routine_fixture!("workspace")
      assert Custode.Routine.get(routine.id).id == routine.id
      assert Custode.Routine.get("nope") == nil
      assert Custode.Routine.default().id == routine.id
    end
  end

  describe "tick_args/1 (the crontab-as-agent-spec)" do
    test "carries the full lifecycle policy and is JSON-clean" do
      routine = routine_fixture!("workspace")
      args = Custode.Routine.tick_args(routine)

      assert args["agent_id"] == routine.id
      assert args["prompt"] == "sweep now"
      assert args["session"] == "fresh"
      assert args["if_busy"] == "skip"
      assert args["if_offline"] == "start"
      assert args["start"]["approved_args"] == %{"permission_mode" => "dont_ask"}
      assert is_integer(args["start"]["job_timeout"])

      # the whole thing must survive the crontab -> oban_jobs JSON round trip
      assert args == args |> Jason.encode!() |> Jason.decode!()
    end

    test "the embedded claude args pin the sandbox" do
      routine = routine_fixture!("workspace")
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert claude_args["working_dir"] == Path.expand("workspace")
      assert claude_args["permission_mode"] == "accept_edits"
      assert is_binary(claude_args["json_schema"])
      assert claude_args["json_schema"] =~ "request_permission"
      assert claude_args["append_system_prompt"] =~ "caretaker"
    end

    test "mcp: true adds the config file, the tool allowlist, and delegation orders" do
      routine = routine_fixture!("workspace", %{mcp: true})
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert claude_args["mcp_config"] == [Custode.MCP.config_path()]
      assert claude_args["allowed_tools"] == ["mcp__custode"]
      assert claude_args["append_system_prompt"] =~ "Delegation"
      assert claude_args["append_system_prompt"] =~ "run_job"
    end

    test "mcp: false gets neither tools nor delegation orders" do
      routine = routine_fixture!("workspace")
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      refute Map.has_key?(claude_args, "mcp_config")
      refute Map.has_key?(claude_args, "allowed_tools")
      refute claude_args["append_system_prompt"] =~ "Delegation"
    end
  end

  describe "sub_agent_args/2" do
    test "defaults: worker-bee prompt, no delegation, sandboxed to the workspace" do
      args = Custode.Routine.sub_agent_args("/tmp")

      assert args["working_dir"] == "/tmp"
      assert args["append_system_prompt"] =~ "sub-agent"
      refute Map.has_key?(args, "mcp_config")
      assert args["permission_mode"] == "accept_edits"
    end

    test "model and system_prompt overrides from tool params" do
      args =
        Custode.Routine.sub_agent_args("/tmp", %{model: "haiku", system_prompt: "review PRs"})

      assert args["model"] == "haiku"
      assert args["append_system_prompt"] == "review PRs"
    end
  end
end
