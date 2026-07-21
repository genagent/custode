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

    test "max_turns defaults to 20 and flows into the claude args when overridden" do
      assert routine_fixture!("workspace").max_turns == 20

      worker = routine_fixture!("workspace", %{max_turns: 75})
      assert Custode.Routine.tick_args(worker)["start"]["args"]["max_turns"] == 75
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
      assert args["start"]["approved_args"] == %{"permission_mode" => "bypass_permissions"}
      assert is_integer(args["start"]["job_timeout"])

      # the whole thing must survive the crontab -> oban_jobs JSON round trip
      assert args == args |> Jason.encode!() |> Jason.decode!()
    end

    test "the embedded claude args pin the sandbox" do
      routine = routine_fixture!("workspace")
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert claude_args["working_dir"] == Path.expand("workspace")
      # bookkeeping is tool-mediated, so routines get NO standing write
      # permission (claude's default mode denies writes non-interactively)
      refute Map.has_key?(claude_args, "permission_mode")
      assert is_binary(claude_args["json_schema"])
      assert claude_args["json_schema"] =~ "request_permission"
      assert claude_args["append_system_prompt"] =~ "caretaker"
      assert claude_args["append_system_prompt"] =~ routine.id
      assert claude_args["append_system_prompt"] =~ "inbox_list"
      assert claude_args["append_system_prompt"] =~ "recall"
    end

    test "mcp: true adds the config file, the tool allowlist, and delegation orders" do
      routine = routine_fixture!("workspace", %{mcp: true})
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert claude_args["mcp_config"] == [Custode.MCP.config_path()]
      assert "mcp__custode__run_job" in claude_args["allowed_tools"]
      assert claude_args["append_system_prompt"] =~ "Delegation"
      assert claude_args["append_system_prompt"] =~ "run_job"
    end

    test "tool tiers: operator verbs go to the caretaker role only (#40)" do
      caretaker = routine_fixture!("workspace", %{mcp: true})
      caretaker_tools = Custode.Routine.tick_args(caretaker)["start"]["args"]["allowed_tools"]

      worker = routine_fixture!("workspace", %{mcp: true, role: :backlog_worker})
      worker_tools = Custode.Routine.tick_args(worker)["start"]["args"]["allowed_tools"]

      for operator_verb <- ~w(pause_agent resume_agent beat drop_note spend_today) do
        assert "mcp__custode__#{operator_verb}" in caretaker_tools
        refute "mcp__custode__#{operator_verb}" in worker_tools
      end

      # workers keep delegation over their own sub-agents and their notebook
      for tool <- ~w(run_job start_agent approve_action journal_append recall) do
        assert "mcp__custode__#{tool}" in worker_tools
      end

      # nobody gets the bare whole-server grant anymore
      refute "mcp__custode" in caretaker_tools
      refute "mcp__custode" in worker_tools
    end

    test "mcp: false gets neither tools nor delegation orders" do
      routine = routine_fixture!("workspace")
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      refute Map.has_key?(claude_args, "mcp_config")
      refute Map.has_key?(claude_args, "allowed_tools")
      refute claude_args["append_system_prompt"] =~ "Delegation"
    end
  end

  describe "repo caretaker (working_dir split, approved worktree, git grants)" do
    defp dev_fixture! do
      routine_fixture!("workspace", %{
        role: :repo_caretaker,
        working_dir: ".",
        mcp: true,
        extra_allowed_tools: ["Bash(git log:*)"],
        approved_args: %{"permission_mode" => "bypass_permissions", "worktree" => "dev-wt"}
      })
    end

    test "working_dir defaults to workspace, and splits when given" do
      plain = routine_fixture!("workspace")
      assert plain.working_dir == "workspace"

      dev = dev_fixture!()
      assert dev.workspace == "workspace"
      assert dev.working_dir == "."

      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]
      assert claude_args["working_dir"] == Path.expand(".")
    end

    test "approved_args override rides the tick spec (worktree isolation)" do
      dev = dev_fixture!()

      assert Custode.Routine.tick_args(dev)["start"]["approved_args"] ==
               %{"permission_mode" => "bypass_permissions", "worktree" => "dev-wt"}

      plain = routine_fixture!("workspace")

      assert Custode.Routine.tick_args(plain)["start"]["approved_args"] ==
               %{"permission_mode" => "bypass_permissions"}
    end

    test "extra_allowed_tools append to the MCP allowlist" do
      dev = dev_fixture!()
      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]

      assert List.last(claude_args["allowed_tools"]) == "Bash(git log:*)"
      assert "mcp__custode__run_job" in claude_args["allowed_tools"]
    end

    test "the repo caretaker role gets its own standing orders" do
      dev = dev_fixture!()
      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]

      assert claude_args["append_system_prompt"] =~ "repository caretaker"
      assert claude_args["append_system_prompt"] =~ "isolated git worktree"
      assert claude_args["append_system_prompt"] =~ "one small, concrete improvement"
      # still gets no standing write permission
      refute Map.has_key?(claude_args, "permission_mode")
    end
  end

  describe "kickoff types" do
    test "cron: :manual routines are excluded from the crontab; scheduled ones remain" do
      workspace = tmp_workspace!()

      put_env!(:routines, [
        %{id: uid("sched"), cron: "@daily", workspace: workspace, prompt: "sweep"},
        %{id: uid("static"), cron: :manual, workspace: workspace, prompt: "on demand"}
      ])

      put_env!(:sensors, [
        %{
          id: "s1",
          cron: "*/30 * * * *",
          module: Custode.Sensors.ContributorSearch,
          notify: "whoever",
          args: %{owners: ["o"]}
        }
      ])

      crontab = Custode.Routine.crontab()
      assert length(crontab) == 2

      assert [{_cron, ObanClaude.Agent.Tick, _opts}] =
               Enum.filter(crontab, &(elem(&1, 1) == ObanClaude.Agent.Tick))

      assert [{"*/30 * * * *", Custode.Sensors.ContributorSearch, sensor_opts}] =
               Enum.filter(crontab, &(elem(&1, 1) == Custode.Sensors.ContributorSearch))

      assert sensor_opts[:queue] == :sensors
      assert sensor_opts[:args]["sensor_id"] == "s1"
      assert sensor_opts[:args]["notify"] == "whoever"
    end

    test "on_note defaults to :beat and accepts :ignore" do
      assert routine_fixture!("workspace").on_note == :beat
      assert routine_fixture!("workspace", %{on_note: :ignore}).on_note == :ignore
    end
  end

  describe "the role library" do
    alias Custode.Routine.Prompts

    test "backlog_worker: gated single-item pace, worktree implementation, gh reads" do
      prompt = Prompts.for_role(:backlog_worker, "rt")
      assert prompt =~ ~s(routine_id "rt")
      assert prompt =~ "at most one item per sweep" |> String.downcase()
      assert prompt =~ "gh issue list"
      assert prompt =~ "isolated git worktree"
      assert prompt =~ "Never start without approval"
    end

    test "star_tracker: snapshot memory and delta reporting" do
      prompt = Prompts.for_role(:star_tracker, "st")
      assert prompt =~ "star-snapshot"
      assert prompt =~ "gh repo list"
      assert prompt =~ "delta"
    end

    test "contributor_watch: sensor-driven judgment, ask_user as the alert channel" do
      prompt = Prompts.for_role(:contributor_watch, "cw")
      assert prompt =~ "seen-items"
      assert prompt =~ "directive=ask_user"
      assert prompt =~ "SENSOR"
      assert prompt =~ "never run your own searches"
    end

    test "roles wire through routine normalization" do
      routine = routine_fixture!("workspace", %{role: :backlog_worker})
      assert routine.system_prompt =~ "backlog"

      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]
      assert claude_args["append_system_prompt"] =~ "backlog worker"
    end
  end

  describe "sub_agent_args/2" do
    test "defaults: worker-bee prompt, memory-only MCP, sandboxed to the workspace" do
      args = Custode.Routine.sub_agent_args("/tmp")

      assert args["working_dir"] == "/tmp"
      assert args["append_system_prompt"] =~ "sub-agent"
      # persistence without delegation: the memory-only server, nothing else
      assert args["mcp_config"] == [Custode.MCP.memory_config_path()]
      assert args["allowed_tools"] == ["mcp__memory"]
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
