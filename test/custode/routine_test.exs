defmodule Custode.RoutineTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Gates.Class
  alias Custode.MCP.Identity
  alias Custode.OperatorSkill

  describe "normalize and defaults" do
    test "fills model, budget, system prompt, and mcp from the shared defaults" do
      routine = routine_fixture!("workspace")

      assert routine.model == Application.fetch_env!(:custode, :model)
      assert routine.provider == :claude
      assert routine.max_budget_usd == Application.fetch_env!(:custode, :max_budget_usd)
      # least privilege by default (#161): no role named means :assistant,
      # never the caretaker's operator toolset
      assert routine.role == :assistant
      assert routine.system_prompt =~ "assistant"
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

    test "Codex is an explicit provider with its own model and approval defaults" do
      routine = routine_fixture!("workspace", %{provider: :codex})

      assert routine.provider == :codex
      assert routine.model == Application.get_env(:custode, :codex_model)

      assert routine.approved_args == %{
               "sandbox" => "workspace_write",
               "approval_policy" => "never"
             }

      assert Custode.Routine.tick_worker(routine) == ObanCodex.Agent.Tick
    end

    test "an unknown provider is rejected during normalization" do
      assert_raise ArgumentError, ~r/unknown routine provider/, fn ->
        routine_fixture!("workspace", %{provider: :other})
      end
    end

    test "max_turns defaults to 20 and flows into the claude args when overridden" do
      assert routine_fixture!("workspace").max_turns == 20

      worker = routine_fixture!("workspace", %{max_turns: 75})
      assert Custode.Routine.tick_args(worker)["start"]["args"]["max_turns"] == 75
    end

    test "ensure_workspaces! creates workspace inboxes; missing working_dirs only warn" do
      base = Path.join(System.tmp_dir!(), uid("ws-ensure"))
      on_exit(fn -> File.rm_rf!(base) end)

      put_env!(:routines, [
        %{id: uid("fresh"), cron: :manual, workspace: Path.join(base, "fresh"), prompt: "x"},
        %{
          id: uid("checkout"),
          cron: :manual,
          workspace: Path.join(base, "nb"),
          working_dir: Path.join(base, "missing-checkout"),
          prompt: "x"
        }
      ])

      assert :ok = Custode.Routine.ensure_workspaces!()

      # workspaces + inboxes exist; the absent checkout was NOT conjured
      assert File.dir?(Path.join([base, "fresh", "inbox"]))
      assert File.dir?(Path.join([base, "nb", "inbox"]))
      refute File.dir?(Path.join(base, "missing-checkout"))
    end

    test "profiles: envelope inherited, routine overrides win, tags union, args template (#75)" do
      put_env!(:profiles, %{
        tester: %{
          cron: "@daily",
          role: :backlog_worker,
          model: "opus",
          max_turns: 75,
          tags: [:repo, :backlog],
          sensors: [:ci],
          prompt: "Do your backlog sweep now.",
          approved_args: %{"permission_mode" => "bypass_permissions", "worktree" => "c-{id}"}
        }
      })

      workspace = tmp_workspace!()

      put_env!(:routines, [
        %{
          id: "prof-a",
          profile: :tester,
          repo: "acme/a",
          workspace: workspace,
          tags: [:rust],
          # the assignment tunes the envelope
          max_turns: 40
        }
      ])

      routine = Custode.Routine.get("prof-a")
      assert routine.model == "opus"
      assert routine.max_turns == 40
      assert routine.role == :backlog_worker
      assert routine.tags == [:repo, :backlog, :rust]
      assert routine.approved_args["worktree"] == "c-prof-a"

      # the profile's sensors: [:ci] derives the poll for the repo
      assert %{id: "ci-prof-a", notify: "prof-a", args: %{repo: "acme/a"}} =
               Enum.find(Custode.Routine.sensors(), &(&1.id == "ci-prof-a"))
    end

    test "role/1 reads explicit, inherited, and default roles without normalizing the roster" do
      put_env!(:profiles, %{tester: %{role: :backlog_worker}})

      put_env!(:routines, [
        %{id: "explicit", role: :caretaker},
        %{
          id: "inherited",
          profile: :tester,
          system_prompt_file: "/missing/role-lookup-must-not-read-this"
        },
        %{id: "default"}
      ])

      assert Custode.Routine.role("explicit") == :caretaker
      assert Custode.Routine.role("inherited") == :backlog_worker
      assert Custode.Routine.role("default") == :assistant
      assert Custode.Routine.role("missing") == nil
    end

    test "specialist profile resolves provider-specific strong models without broader authority" do
      workspace = tmp_workspace!()

      put_env!(:routines, [
        %{id: "claude-specialist", profile: :specialist, provider: :claude, workspace: workspace},
        %{id: "codex-specialist", profile: :specialist, provider: :codex, workspace: workspace}
      ])

      claude = Custode.Routine.get("claude-specialist")
      codex = Custode.Routine.get("codex-specialist")

      assert {claude.model, claude.effort} == {"opus", :high}
      assert {codex.model, codex.effort} == {"gpt-5.6-sol", :high}
      assert claude.max_turns > 75
      assert claude.timeout_ms > 900_000
      assert Custode.Roles.grants(claude.role) == :worker
      assert Custode.Roles.grants(codex.role) == :worker
    end

    test "a provider change cannot silently retain a known incompatible model" do
      assert_raise ArgumentError, ~r/Claude model opus cannot be used by a Codex routine/, fn ->
        routine_fixture!("workspace", %{profile: :specialist, provider: :codex, model: "opus"})
      end

      assert_raise ArgumentError,
                   ~r/Codex model gpt-5.6-sol cannot be used by a Claude routine/,
                   fn ->
                     routine_fixture!("workspace", %{
                       profile: :specialist,
                       provider: :claude,
                       model: "gpt-5.6-sol"
                     })
                   end
    end

    test "system_prompt_file composes charter + file body; hermetic passes through (#19/#17)" do
      dir = Path.join(System.tmp_dir!(), uid("pfile"))
      File.mkdir_p!(dir)
      path = Path.join(dir, "orders.md")
      File.write!(path, "## Your role: file-grown\nDo the file thing.")
      on_exit(fn -> File.rm_rf!(dir) end)

      routine =
        routine_fixture!(tmp_workspace!(), %{system_prompt_file: path, hermetic: true})

      assert routine.system_prompt =~ "## Charter"
      assert routine.system_prompt =~ "Do the file thing."

      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]
      assert claude_args["hermetic"] == true
      refute Map.has_key?(claude_args, "setting_sources")

      plain = routine_fixture!(tmp_workspace!())
      plain_args = Custode.Routine.tick_args(plain)["start"]["args"]
      refute Map.has_key?(plain_args, "hermetic")
      assert plain_args["setting_sources"] == "project,local"

      false_scope = routine_fixture!(tmp_workspace!(), %{hermetic: false})
      assert false_scope.hermetic == nil

      assert Custode.Routine.tick_args(false_scope)["start"]["args"]["setting_sources"] ==
               "project,local"

      full_scope = routine_fixture!(tmp_workspace!(), %{hermetic: :full})
      full_args = Custode.Routine.tick_args(full_scope)["start"]["args"]
      assert full_args["hermetic"] == "full"
      refute Map.has_key?(full_args, "setting_sources")
    end

    test "rejects Claude's project hermetic scope because it loads user settings" do
      assert_raise ArgumentError, ~r/project scope loads user settings/, fn ->
        routine_fixture!(tmp_workspace!(), %{hermetic: :project})
      end
    end

    test "workspace defaults to workspaces/<id> when omitted" do
      put_env!(:routines, [%{id: "ws-less", cron: :manual, prompt: "x"}])

      assert Custode.Routine.get("ws-less").workspace ==
               Custode.Home.resolve("workspaces/ws-less")
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
      assert String.starts_with?(args["prompt"], "sweep now")
      assert args["prompt"] =~ "Operator presence"
      assert args["session"] == "fresh"
      assert args["if_busy"] == "skip"
      assert args["if_offline"] == "start"

      assert args["start"]["approved_args"] == %{
               "permission_mode" => "bypass_permissions",
               "setting_sources" => "project,local"
             }

      assert is_integer(args["start"]["job_timeout"])
      assert args["start"]["config_revision"] == Custode.Routine.execution_revision(routine)
      assert args["delivery_revision"] == Custode.Routine.delivery_revision(routine)

      context_path = Path.join(Path.expand(routine.workspace), "HANDOFF.md")
      assert args["start"]["args"]["custode_context_path"] == context_path
      assert args["start"]["args"]["append_system_prompt"] =~ context_path
      assert File.exists?(context_path)

      # the whole thing must survive the crontab -> oban_jobs JSON round trip
      assert args == args |> Jason.encode!() |> Jason.decode!()
    end

    test "execution revision classifies provider state separately from delivery policy" do
      workspace = tmp_workspace!()
      alternate_workspace = tmp_workspace!()
      id = uid("execution-revision")

      base = %{
        id: id,
        provider: :claude,
        cron: "@daily",
        workspace: workspace,
        working_dir: workspace,
        prompt: "sweep",
        model: "haiku",
        effort: :low,
        system_prompt: "follow the first contract",
        max_turns: 20,
        max_budget_usd: 1.0,
        timeout_ms: 200_000,
        approved_args: %{"permission_mode" => "bypass_permissions"},
        extra_allowed_tools: []
      }

      put_env!(:routines, [base])

      revision = fn changes ->
        Application.put_env(:custode, :routines, [Map.merge(base, changes)])
        Custode.Routine.default() |> Custode.Routine.execution_revision()
      end

      original = revision.(%{})

      delivery_revision = fn changes ->
        Application.put_env(:custode, :routines, [Map.merge(base, changes)])
        Custode.Routine.default() |> Custode.Routine.delivery_revision()
      end

      original_delivery = delivery_revision.(%{})

      for changes <- [
            %{provider: :codex, model: "gpt-5.6-sol"},
            %{model: "sonnet"},
            %{effort: :high},
            %{system_prompt: "follow the second contract"},
            %{role: :backlog_worker},
            %{repo: "genagent/other"},
            %{role: :backlog_worker, mcp: true},
            %{extra_allowed_tools: ["Bash(git status:*)"]},
            %{workspace: alternate_workspace},
            %{working_dir: alternate_workspace},
            %{max_turns: 40},
            %{max_budget_usd: 2.0},
            %{approved_args: %{"permission_mode" => "accept_edits"}},
            %{timeout_ms: 300_000},
            %{hermetic: true},
            %{agent: "reviewer"}
          ] do
        refute revision.(changes) == original,
               "expected provider launch change #{inspect(changes)} to rotate the config revision"
      end

      # These values are read by Custode at delivery time. They do not live
      # inside the provider process and therefore must not churn an idle
      # process or rotate a compatible native conversation arc.
      for changes <- [
            %{prompt: "a different sweep"},
            %{cron: "@hourly"},
            %{daily_budget_usd: 10.0},
            %{daily_budget_tokens: 1_000_000},
            %{on_note: :ignore},
            %{sensors: [:ci]}
          ] do
        assert revision.(changes) == original,
               "expected delivery policy change #{inspect(changes)} to keep the config revision"
      end

      refute delivery_revision.(%{prompt: "a different sweep"}) == original_delivery

      for changes <- [
            %{cron: "@hourly"},
            %{daily_budget_usd: 10.0},
            %{daily_budget_tokens: 1_000_000},
            %{on_note: :ignore},
            %{sensors: [:ci]}
          ] do
        assert delivery_revision.(changes) == original_delivery,
               "expected non-prompt delivery policy #{inspect(changes)} to keep the delivery revision"
      end
    end

    test "Codex bearer token remints rotate execution and queued delivery" do
      routine =
        routine_fixture!(tmp_workspace!(), %{
          provider: :codex,
          mcp: true,
          role: :backlog_worker
        })

      assert :error = Identity.token(:routine, routine.id)
      missing_revision = Custode.Routine.execution_revision(routine)
      assert :error = Identity.token(:routine, routine.id)

      :ok = Custode.MCP.write_routine_config!(routine.id)
      {:ok, original_token} = Identity.token(:routine, routine.id)
      original_revision = Custode.Routine.execution_revision(routine)
      refute original_revision == missing_revision

      start = Custode.Routine.tick_args(routine)["start"]
      original_delivery_revision = Custode.Routine.delivery_revision(routine)
      assert {:ok, ^original_token} = Identity.token(:routine, routine.id)
      assert start["config_revision"] == original_revision

      reminted_token = Identity.mint(:routine, routine.id)
      refute reminted_token == original_token

      refute Custode.Routine.execution_revision(routine) == original_revision
      refute Custode.Routine.delivery_revision(routine) == original_delivery_revision

      tick = Custode.Routine.tick_args(routine)
      start = tick["start"]
      assert start["config_revision"] == Custode.Routine.execution_revision(routine)
      assert tick["delivery_revision"] == Custode.Routine.delivery_revision(routine)
      assert {:ok, ^reminted_token} = Identity.token(:routine, routine.id)

      authorization =
        start["args"]["config_overrides"]
        |> Enum.find(&String.starts_with?(&1, "mcp_servers.custode.http_headers.Authorization="))

      assert authorization ==
               "mcp_servers.custode.http_headers.Authorization=" <>
                 Jason.encode!("Bearer " <> reminted_token)
    end

    test "semantic external MCP changes rotate Claude and Codex revisions" do
      first_server = %{
        name: "reference",
        type: :http,
        url: "https://one.example/mcp",
        allowed: ["mcp__reference__search"]
      }

      put_env!(:external_mcp_servers, [first_server])

      for provider <- [:claude, :codex] do
        routine =
          routine_fixture!(tmp_workspace!(), %{
            provider: provider,
            mcp: true,
            role: :backlog_worker
          })

        original_revision = Custode.Routine.execution_revision(routine)

        Application.put_env(:custode, :external_mcp_servers, [
          %{first_server | url: "https://two.example/mcp"}
        ])

        refute Custode.Routine.execution_revision(routine) == original_revision,
               "expected #{provider} external MCP URL change to rotate the config revision"

        Application.put_env(:custode, :external_mcp_servers, [first_server])
      end
    end

    test "live presence changes sweep prompts without rotating the execution revision" do
      put_env!(:presence_override, :away)

      instructions = fn provider, args ->
        case provider do
          :claude ->
            args["append_system_prompt"]

          :codex ->
            args["config_overrides"]
            |> Enum.find(&String.starts_with?(&1, "developer_instructions="))
            |> String.replace_prefix("developer_instructions=", "")
            |> Jason.decode!()
        end
      end

      for provider <- [:claude, :codex] do
        routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
        away = Custode.Routine.tick_args(routine)
        refute instructions.(provider, away["start"]["args"]) =~ "Operator presence"
        assert away["prompt"] =~ "operator: AWAY"

        Application.put_env(:custode, :presence_override, :present)
        present = Custode.Routine.tick_args(routine)
        assert present["prompt"] =~ "operator: PRESENT"

        assert present["start"]["config_revision"] ==
                 away["start"]["config_revision"]

        refute present["delivery_revision"] == away["delivery_revision"]

        Application.put_env(:custode, :presence_override, :away)
      end
    end

    test "static instructions, binding policy and ambient orders rotate the revision" do
      workspace = tmp_workspace!()
      orders_path = Path.join([workspace, ".custode", "orders.md"])
      File.mkdir_p!(Path.dirname(orders_path))
      File.write!(orders_path, "Use the first repository workflow.")

      first_policy = %{id: :execution_contract, applies: :all, text: "Follow the first policy."}
      put_env!(:policies, [first_policy])
      put_env!(:ambient_orders, :all)

      routine =
        routine_fixture!(workspace, %{
          working_dir: workspace,
          system_prompt: "Follow the first standing instructions."
        })

      original_revision = Custode.Routine.execution_revision(routine)

      refute Custode.Routine.execution_revision(%{
               routine
               | system_prompt: "Follow the second standing instructions."
             }) == original_revision

      Application.put_env(:custode, :policies, [
        %{first_policy | text: "Follow the second policy."}
      ])

      refute Custode.Routine.execution_revision(routine) == original_revision

      Application.put_env(:custode, :policies, [first_policy])
      File.write!(orders_path, "Use the second repository workflow.")
      refute Custode.Routine.execution_revision(routine) == original_revision
    end

    test "a routine may run as a repo-owned persona (#19: agent passthrough)" do
      routine = routine_fixture!("workspace", %{agent: "backlog-slicer"})
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]
      assert claude_args["agent"] == "backlog-slicer"

      # and absent stays absent: claude runs as itself by default
      plain = routine_fixture!("workspace")
      refute Map.has_key?(Custode.Routine.tick_args(plain)["start"]["args"], "agent")
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

      # the schema'd epilogue (#120 slice 2): what the sweep touched arrives
      # as optional integer arrays, so nothing has to parse the summary
      schema = Jason.decode!(claude_args["json_schema"])

      assert schema["properties"]["prs"] == %{
               "type" => "array",
               "items" => %{"type" => "integer"},
               "description" => "PR numbers this sweep opened, pushed to, or acted on"
             }

      assert schema["properties"]["issues_touched"]["type"] == "array"
      assert schema["properties"]["issues_touched"]["items"] == %{"type" => "integer"}
      # a sweep that touched nothing must still validate
      assert schema["required"] == ["directive", "summary"]
      assert schema["properties"]["answer"]["type"] == ["string", "null"]
      refute Map.has_key?(schema["properties"]["answer"], "maxLength")
      assert schema["properties"]["report"]["additionalProperties"] == false
      assert schema["properties"]["report"]["properties"]["done"]["maxItems"] == 3

      # the class of a gated action (#451): an enum of the one list, and
      # optional, so a turn that omits it is still valid output
      assert schema["properties"]["action_class"]["enum"] == Class.ids()
      assert schema["properties"]["action_class"]["description"] =~ "ready_pr = mark a draft"
      assert claude_args["append_system_prompt"] =~ "action_class"
      assert claude_args["append_system_prompt"] =~ "assistant"
      assert claude_args["append_system_prompt"] =~ routine.id
      assert claude_args["append_system_prompt"] =~ "inbox_list"
      assert claude_args["append_system_prompt"] =~ "recall"
    end

    test "mcp: true adds the config file, the tool allowlist, and delegation orders" do
      routine = routine_fixture!("workspace", %{mcp: true})
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert List.first(claude_args["mcp_config"]) == Custode.MCP.config_path(routine.id)
      assert "mcp__custode__run_job" in claude_args["allowed_tools"]
      assert claude_args["append_system_prompt"] =~ "Delegation"
      assert claude_args["append_system_prompt"] =~ "run_job"
    end

    test "phase-split models: cheap sweeps, expensive approved implementations" do
      put_env!(:profiles, %{
        split: %{
          role: :backlog_worker,
          cron: :manual,
          model: "sonnet",
          effort: "low",
          approved_args: %{"model" => "opus", "effort" => "high"}
        }
      })

      routine = routine_fixture!(tmp_workspace!(), %{profile: :split})
      start = Custode.Routine.tick_args(routine)["start"]

      assert start["args"]["model"] == "sonnet"
      assert start["args"]["effort"] == "low"
      assert start["approved_args"]["model"] == "opus"
      assert start["approved_args"]["effort"] == "high"
    end

    test "tool tiers: operator verbs go to the caretaker role only (#40)" do
      caretaker = routine_fixture!("workspace", %{mcp: true, role: :caretaker})
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

    test "set_panel is verb-gated on the panels mode (#100)" do
      previous = Application.get_env(:custode, :agent_panels)
      on_exit(fn -> Application.put_env(:custode, :agent_panels, previous) end)

      put_env!(:agent_panels, :gated)
      worker = routine_fixture!("workspace", %{mcp: true, role: :backlog_worker})
      tools = Custode.Routine.tick_args(worker)["start"]["args"]["allowed_tools"]
      assert "mcp__custode__set_panel" in tools

      # :off removes the verb from the allowlist entirely
      put_env!(:agent_panels, :off)
      off = routine_fixture!("workspace", %{mcp: true, role: :backlog_worker})
      off_tools = Custode.Routine.tick_args(off)["start"]["args"]["allowed_tools"]
      refute "mcp__custode__set_panel" in off_tools
    end

    test "mcp: false gets neither tools nor delegation orders" do
      routine = routine_fixture!("workspace")
      claude_args = Custode.Routine.tick_args(routine)["start"]["args"]

      refute Map.has_key?(claude_args, "mcp_config")
      refute Map.has_key?(claude_args, "allowed_tools")
      refute claude_args["append_system_prompt"] =~ "Delegation"
    end

    test "Codex receives its sandbox, schema, reasoning and MCP server config" do
      routine =
        routine_fixture!(tmp_workspace!(), %{
          provider: :codex,
          model: "gpt-6",
          effort: "high",
          hermetic: true,
          mcp: true,
          role: :backlog_worker
        })

      :ok = Custode.MCP.write_routine_config!(routine.id)
      args = Custode.Routine.tick_args(routine)["start"]["args"]

      assert args["model"] == "gpt-6"
      assert args["sandbox"] == "read_only"
      assert args["approval_policy"] == "never"
      assert args["ignore_rules"] == true
      assert args["strict_config"] == true
      assert args["skip_git_repo_check"] == true

      assert args["custode_context_path"] ==
               Path.join(Path.expand(routine.workspace), "HANDOFF.md")

      assert File.exists?(args["output_schema"])

      codex_schema = Jason.decode!(File.read!(args["output_schema"]))

      assert MapSet.new(codex_schema["required"]) ==
               MapSet.new(Map.keys(codex_schema["properties"]))

      for field <- ~w(action action_class issues_touched prs question repo) do
        assert %{"anyOf" => choices} = codex_schema["properties"][field]
        assert %{"type" => "null"} in choices
      end

      [report_schema, %{"type" => "null"}] = codex_schema["properties"]["report"]["anyOf"]

      assert MapSet.new(report_schema["required"]) ==
               MapSet.new(Map.keys(report_schema["properties"]))

      refute Map.has_key?(codex_schema["properties"]["directive"], "anyOf")
      refute Map.has_key?(codex_schema["properties"]["summary"], "anyOf")

      assert codex_schema["properties"]["answer"]["type"] == ["string", "null"]
      assert "answer" in codex_schema["required"]
      refute Map.has_key?(codex_schema["properties"]["answer"], "maxLength")

      overrides = args["config_overrides"]
      operator_skill = Path.join(OperatorSkill.destination(:codex), "SKILL.md")

      assert "skills.config=[{path=#{Jason.encode!(operator_skill)},enabled=false}]" in overrides
      assert Enum.any?(overrides, &String.starts_with?(&1, "developer_instructions="))
      assert Enum.any?(overrides, &String.contains?(&1, args["custode_context_path"]))
      assert "model_reasoning_effort=\"high\"" in overrides
      assert Enum.any?(overrides, &String.starts_with?(&1, "mcp_servers.custode.url="))
      assert Enum.any?(overrides, &String.starts_with?(&1, "mcp_servers.hexpm.url="))
      refute Enum.any?(overrides, &String.starts_with?(&1, ~s(mcp_servers.")))

      enabled =
        Enum.find(overrides, &String.starts_with?(&1, "mcp_servers.custode.enabled_tools="))

      assert enabled =~ "repo_list_prs"
      refute enabled =~ "mcp__custode__"
    end

    test "a normal Codex routine cannot select the global operator skill" do
      routine =
        routine_fixture!(tmp_workspace!(), %{
          provider: :codex,
          approved_args: %{
            "sandbox" => "workspace_write",
            "strict_config" => false,
            "config_overrides" => ["skills.config=[{path=\"bad\",enabled=true}]"]
          }
        })

      start = Custode.Routine.tick_args(routine)["start"]
      args = start["args"]
      approved = start["approved_args"]
      operator_skill = Path.join(OperatorSkill.destination(:codex), "SKILL.md")
      disabled = "skills.config=[{path=#{Jason.encode!(operator_skill)},enabled=false}]"

      assert disabled in args["config_overrides"]
      assert args["strict_config"] == true
      assert approved["config_overrides"] == args["config_overrides"]
      assert approved["strict_config"] == true
      refute Enum.any?(approved["config_overrides"], &String.contains?(&1, "path=\"bad\""))

      refute args["ignore_rules"]
    end

    test "approved Claude continuations cannot restore the global user source" do
      routine =
        routine_fixture!(tmp_workspace!(), %{
          approved_args: %{
            "permission_mode" => "bypass_permissions",
            "setting_sources" => "user,project,local",
            "hermetic" => "project"
          }
        })

      start = Custode.Routine.tick_args(routine)["start"]
      assert start["args"]["setting_sources"] == "project,local"
      refute Map.has_key?(start["args"], "hermetic")
      assert start["approved_args"]["setting_sources"] == "project,local"
      refute Map.has_key?(start["approved_args"], "hermetic")

      sealed =
        routine_fixture!(tmp_workspace!(), %{
          hermetic: true,
          approved_args: routine.approved_args
        })

      sealed_start = Custode.Routine.tick_args(sealed)["start"]
      assert sealed_start["args"]["hermetic"] == true
      refute Map.has_key?(sealed_start["args"], "setting_sources")
      assert sealed_start["approved_args"]["hermetic"] == true
      refute Map.has_key?(sealed_start["approved_args"], "setting_sources")
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
      # normalize roots relative paths under Custode.Home (cwd in source mode)
      assert plain.working_dir == Custode.Home.resolve("workspace")

      dev = dev_fixture!()
      assert dev.workspace == Custode.Home.resolve("workspace")
      assert dev.working_dir == Custode.Home.resolve(".")

      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]
      assert claude_args["working_dir"] == Path.expand(".")
    end

    test "approved_args override rides the tick spec (worktree isolation)" do
      dev = dev_fixture!()

      assert Custode.Routine.tick_args(dev)["start"]["approved_args"] ==
               %{
                 "permission_mode" => "bypass_permissions",
                 "setting_sources" => "project,local",
                 "worktree" => "dev-wt",
                 "mcp_config" => [Custode.MCP.config_path(dev.id)],
                 "strict_mcp_config" => true
               }

      plain = routine_fixture!("workspace")

      assert Custode.Routine.tick_args(plain)["start"]["approved_args"] ==
               %{
                 "permission_mode" => "bypass_permissions",
                 "setting_sources" => "project,local"
               }
    end

    test "extra_allowed_tools append to the MCP allowlist" do
      dev = dev_fixture!()
      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]

      assert "Bash(git log:*)" in claude_args["allowed_tools"]
      assert "mcp__custode__run_job" in claude_args["allowed_tools"]
    end

    test "the repo caretaker role gets its own standing orders" do
      dev = dev_fixture!()
      claude_args = Custode.Routine.tick_args(dev)["start"]["args"]

      assert claude_args["append_system_prompt"] =~ "repository caretaker"
      assert claude_args["append_system_prompt"] =~ "git worktree"
      assert claude_args["append_system_prompt"] =~ "one small, concrete improvement"
      # still gets no standing write permission
      refute Map.has_key?(claude_args, "permission_mode")
    end
  end

  describe "kickoff types" do
    test "routines are no longer in the crontab; sensors and the janitor remain" do
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
      # one sensor + the always-on janitor + the three deterministic advisors
      # (#125's trio) + the weekly judgment advisor Retro (#262) + Dryness
      # (#274, deterministic, raises a launch gate rather than a suggestion) --
      # routine firing moved to Custode.Scheduler (#142), so no routine ticks
      # ride the static crontab, and the lease reconciler (#430) is disabled
      # by config/test.exs so its */15 inserts cannot land inside other tests
      assert length(crontab) == 6
      refute Enum.any?(crontab, &(elem(&1, 1) == Custode.Advisors.Model))
      refute Enum.any?(crontab, &(elem(&1, 1) == Custode.RoutineTick))
      refute Enum.any?(crontab, &(elem(&1, 1) == ObanClaude.Agent.Tick))
      refute Enum.any?(crontab, &(elem(&1, 1) == Custode.WorkspaceLeases.ReconcileJob))

      for advisor <- [
            Custode.Advisors.Cadence,
            Custode.Advisors.Budget,
            Custode.Advisors.Retro,
            Custode.Advisors.Dryness
          ] do
        assert Enum.any?(crontab, &(elem(&1, 1) == advisor))
      end

      assert [{"*/30 * * * *", Custode.Sensors.ContributorSearch, sensor_opts}] =
               Enum.filter(crontab, &(elem(&1, 1) == Custode.Sensors.ContributorSearch))

      assert sensor_opts[:queue] == :sensors
      assert sensor_opts[:args]["sensor_id"] == "s1"
      assert sensor_opts[:args]["notify"] == "whoever"

      # register restoration of the test-env `false`, then exercise the
      # UNSET default: every 15 minutes, well under the one-hour lease TTL,
      # riding the same static lane as the janitor (#430).
      put_env!(:workspace_lease_reconcile_cron, false)
      Application.delete_env(:custode, :workspace_lease_reconcile_cron)

      assert [{"*/15 * * * *", Custode.WorkspaceLeases.ReconcileJob, lease_opts}] =
               Enum.filter(
                 Custode.Routine.crontab(),
                 &(elem(&1, 1) == Custode.WorkspaceLeases.ReconcileJob)
               )

      assert lease_opts[:queue] == :sensors

      # A configured cron string is honored, not just the default.
      Application.put_env(:custode, :workspace_lease_reconcile_cron, "*/5 * * * *")

      assert [{"*/5 * * * *", Custode.WorkspaceLeases.ReconcileJob, _opts}] =
               Enum.filter(
                 Custode.Routine.crontab(),
                 &(elem(&1, 1) == Custode.WorkspaceLeases.ReconcileJob)
               )

      # And false removes the line without touching the rest.
      Application.put_env(:custode, :workspace_lease_reconcile_cron, false)
      disabled = Custode.Routine.crontab()
      refute Enum.any?(disabled, &(elem(&1, 1) == Custode.WorkspaceLeases.ReconcileJob))
      assert length(disabled) == 6
    end

    test "on_note defaults to :beat and accepts :ignore" do
      assert routine_fixture!("workspace").on_note == :beat
      assert routine_fixture!("workspace", %{on_note: :ignore}).on_note == :ignore
    end

    test "advisors are config-driven: cron overrides, false disables, unknown raises (#260)" do
      previous = Application.get_env(:custode, :advisors)
      on_exit(fn -> Application.put_env(:custode, :advisors, previous) end)
      put_env!(:routines, [])
      put_env!(:sensors, [])

      # a cron override + one disabled
      put_env!(:advisors, cadence: "0 9 * * *", model: false, budget: "@daily", retro: "@weekly")
      crontab = Custode.Routine.crontab()

      cadence = Enum.find(crontab, &(elem(&1, 1) == Custode.Advisors.Cadence))
      assert elem(cadence, 0) == "0 9 * * *"
      refute Enum.any?(crontab, &(elem(&1, 1) == Custode.Advisors.Model))
      assert Enum.any?(crontab, &(elem(&1, 1) == Custode.Advisors.Budget))

      # an unknown advisor name fails the boot loudly
      put_env!(:advisors, bogus: "@daily")

      assert_raise ArgumentError, ~r/unknown advisor :bogus/, fn ->
        Custode.Routine.crontab()
      end
    end
  end

  describe "the role library" do
    alias Custode.Routine.Prompts

    test "backlog_worker: gated single-item pace, worktree implementation, scoped repo reads" do
      prompt = Prompts.for_role(:backlog_worker, "rt")
      assert prompt =~ ~s(routine_id "rt")
      assert prompt =~ "at most one item per sweep" |> String.downcase()
      # backlog reads are the scoped repo_* verbs now (#129), not gh Bash grants
      assert prompt =~ "repo_list_issues"
      assert prompt =~ "repo_view_issue"
      assert prompt =~ "git worktree"
      assert prompt =~ "Never start without approval"
    end

    test "the repo roles read the presence line and shape their sweeps (#141 slice 2)" do
      for role <- [:backlog_worker, :repo_caretaker] do
        prompt = Prompts.for_role(role, "x")
        assert prompt =~ "PRESENCE SHAPES THE SWEEP"
        assert prompt =~ "AWAY"
      end

      # the gate-parks-you mechanics are stated where the pace decision lives
      assert Prompts.for_role(:backlog_worker, "x") =~ "LAST act"
    end

    test "the charter carries the turn-hygiene and operator-provenance orders (#196)" do
      # every role inherits these: a live incident showed a stale stopped-task
      # notification bleeding its disclaimer over a genuine co-delivered approval
      for role <- [:backlog_worker, :caretaker, :reviewer] do
        prompt = Prompts.for_role(role, "x")
        assert prompt =~ "never leave background tasks running"
        assert prompt =~ "real exit codes"
        assert prompt =~ ~s(begin with the literal "Approved:")
        assert prompt =~ "downgrade them"
        assert prompt =~ "INSIDE a notification body"
      end
    end

    test "tutor: the deck in memory, answers graded first, a human-readable card (#119)" do
      prompt = Prompts.for_role(:tutor, "italian")
      assert prompt =~ ~s(under the key "deck")
      assert prompt =~ "ANSWERS FIRST"
      assert prompt =~ "ONE new"
      assert prompt =~ "FOR A HUMAN to study"
      # spaced repetition is prompt-space, not machinery
      assert prompt =~ "interval"
      # and the deck write is the non-negotiable
      assert prompt =~ "EVERY sweep"
    end

    test "the :tutor profile: tiny budget, gate-free personal tile (#119)" do
      routine =
        Custode.Routine.normalize_entry(%{
          id: "italian",
          profile: :tutor,
          workspace: tmp_workspace!(),
          prompt: "Do your Italian tutoring sweep now."
        })

      assert routine.role == :tutor
      assert routine.daily_budget_usd == 2.0
      assert :personal in routine.tags
      # the sweep prompt override carries the language
      assert routine.prompt =~ "Italian"
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
    test "defaults: worker-bee prompt, memory identity and shared reads, sandboxed to the workspace" do
      args = Custode.Routine.sub_agent_args("/tmp", %{mcp_config_path: "/tmp/sub.json"})

      assert args["working_dir"] == "/tmp"
      assert args["append_system_prompt"] =~ "sub-agent"
      # Persistence and catalog reads, without fleet lifecycle or delegation.
      assert List.first(args["mcp_config"]) == "/tmp/sub.json"
      assert "mcp__memory" in args["allowed_tools"]
      refute Enum.any?(args["allowed_tools"], &String.starts_with?(&1, "mcp__custode"))
      assert args["strict_mcp_config"]
      assert args["permission_mode"] == "accept_edits"
      assert args["setting_sources"] == "project,local"
    end

    test "model and system_prompt overrides from tool params" do
      args =
        Custode.Routine.sub_agent_args("/tmp", %{
          model: "haiku",
          system_prompt: "review PRs",
          mcp_config_path: "/tmp/sub.json"
        })

      assert args["model"] == "haiku"
      assert args["append_system_prompt"] == "review PRs"
    end
  end
end
