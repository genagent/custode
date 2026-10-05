defmodule Custode.WorkflowExecutionPolicyTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.{Repo, Workflow}

  alias Custode.Workflow.{
    Catalog,
    Definition,
    ExecutionPolicy,
    Node,
    NodeJob,
    ResultContract,
    Results,
    Run,
    Runner,
    Stage
  }

  defmodule CaptureRunner do
    @behaviour ClaudeWrapper.Runner
    def run(_binary, args, opts, timeout) do
      send(
        Application.fetch_env!(:custode, :workflow_policy_test_pid),
        {:wrapper_argv, args, opts, timeout}
      )

      if Application.get_env(:custode, :workflow_policy_test_failure) do
        {:error, :timeout}
      else
        {:ok,
         {Jason.encode!(%{
            "type" => "result",
            "subtype" => "success",
            "is_error" => false,
            "result" => "fixture",
            "structured_output" => %{"value" => 7}
          }), 0}}
      end
    end

    def stream_lines(_, _, _, _), do: raise("unexpected streaming")
  end

  setup do
    old = Application.fetch_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, CaptureRunner)
    put_env!(:workflow_policy_test_pid, self())

    on_exit(fn ->
      case old do
        {:ok, value} -> Application.put_env(:claude_wrapper, :runner, value)
        :error -> Application.delete_env(:claude_wrapper, :runner)
      end
    end)

    :ok
  end

  test "profile is explicit, validated and does not change historical default fingerprints" do
    default = definition(nil)
    before = default |> Map.from_struct() |> Map.delete(:execution_profile)
    assert Definition.snapshot(default) == Definition.snapshot(before)
    refute Map.has_key?(Definition.snapshot(default), "execution_profile")
    assert :ok = Workflow.validate(definition(ExecutionPolicy.profile()))

    assert {:error, "unsupported workflow execution profile"} =
             Workflow.validate(%{default | execution_profile: "future"})

    for workflow <- Map.values(Catalog.all()), do: assert(workflow.execution_profile == nil)
  end

  test "actual worker and released wrapper emit empty tools and sealed configuration without a model call" do
    %{run: run, job: job} = launch()
    assert job.args["max_turns"] == 1
    assert job.args["mcp_config"] == []
    assert :ok = ResultContract.launch_check(job)
    assert :ok = NodeJob.perform(job)
    assert_receive {:wrapper_argv, args, opts, 900_000}
    assert flag(args, "--tools") == ""
    assert flag(args, "--setting-sources") == ""
    assert flag(args, "--max-turns") == "1"
    assert flag(args, "--permission-mode") == "plan"
    assert flag(args, "--output-format") == "json"
    assert flag(args, "--json-schema") == job.args["json_schema"]

    assert flag(args, "--system-prompt") ==
             "Analyse only the supplied workflow input. No tools. Return the requested structured output."

    assert flag(args, "--max-budget-usd") == "0.5"
    assert flag(args, "--settings") == ~s({"disableAllHooks":true})
    assert "--strict-mcp-config" in args
    assert "--exclude-dynamic-system-prompt-sections" in args
    assert "--disable-slash-commands" in args
    assert "--no-session-persistence" in args

    for rejected <-
          ~w(--mcp-config --resume --session-id --agent --plugin-dir --allowed-tools --append-system-prompt --system-prompt-file --bare --dangerously-skip-permissions),
        do: refute(rejected in args)

    assert opts[:cd] == job.args["working_dir"]
    assert [%{result: %{"value" => 7}, validation: validation}] = Results.for_run(run.run_id)
    assert validation["contract"]["execution_policy"]["profile"] == ExecutionPolicy.profile()
    assert validation["contract"]["execution_policy"]["native_conformance"] == "unverified"
    assert validation["physical_settlement"] == "unattested"
    assert Run.get(run.run_id).status == "complete"
    assert {:error, :workflow_execution_not_current} = ResultContract.launch_check(job)
    refute_receive {:wrapper_argv, _, _, _}
  end

  test "actual selected worker failure keeps normal stage failure and never fabricates output" do
    put_env!(:workflow_policy_test_failure, true)
    %{run: run, job: job} = launch()
    assert {:error, :timeout} = NodeJob.perform(job)
    assert_receive {:wrapper_argv, _, _, 900_000}
    assert Run.get(run.run_id).status == "failed"
    assert Run.get(run.run_id).failure_identity["callback_job_id"] == job.id
    assert Results.for_run(run.run_id) == []
    assert {:error, :workflow_execution_not_current} = ResultContract.launch_check(job)
    refute_receive {:wrapper_argv, _, _, _}
  end

  test "unsafe stored options and profile substitutions refuse before adapter dispatch even with rebuilt receipts" do
    %{run: run, job: job} = launch()

    for {key, value} <- [
          {"resume", "old"},
          {"allowed_tools", ["Bash"]},
          {"agent", "ambient"},
          {"binary", "/untrusted"},
          {"max_turns", 30},
          {"max_budget_usd", 999},
          {"working_dir", "/unrelated"},
          {"timeout", 1_000_000},
          {"timeout", 10_000},
          {"mcp_config", ["ambient.json"]},
          {"hermetic", "project"}
        ] do
      args = Map.put(job.args, key, value)
      meta = Map.put(job.meta, "result_contract", ResultContract.capture(run, args, job.meta))
      changed = job |> Ecto.Changeset.change(args: args, meta: meta) |> Repo.update!()
      assert {:error, :workflow_execution_policy_unbound} = ResultContract.launch_check(changed)
      assert {:cancel, :workflow_execution_policy_unbound} = NodeJob.perform(changed)
      refute_receive {:wrapper_argv, _, _, _}
      assert Results.for_run(run.run_id) == []
      changed |> Ecto.Changeset.change(args: job.args, meta: job.meta) |> Repo.update!()
    end

    for meta <- [
          Map.delete(job.meta, "result_contract"),
          update_in(job.meta, ["result_contract"], &Map.delete(&1, "execution_policy"))
        ] do
      changed = job |> Ecto.Changeset.change(meta: meta) |> Repo.update!()
      assert {:error, :workflow_execution_policy_unbound} = ResultContract.launch_check(changed)
      refute_receive {:wrapper_argv, _, _, _}
    end
  end

  test "missing host contract or changed captured profile cannot downgrade selected work to legacy" do
    %{run: run, job: job} = launch()
    row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))
    legacy_context = Map.delete(run.context, "result_contract_version")

    for snapshot <- [
          run.definition_snapshot,
          Map.put(run.definition_snapshot, "execution_profile", "future"),
          Map.delete(run.definition_snapshot, "execution_profile")
        ] do
      row
      |> Ecto.Changeset.change(
        context: Jason.encode!(legacy_context),
        definition_snapshot: Jason.encode!(snapshot)
      )
      |> Repo.update!()

      assert {:error, _} = ResultContract.launch_check(job)
      assert {:cancel, _} = NodeJob.perform(job)

      assert :ok =
               NodeJob.handle_result(
                 %ClaudeWrapper.Result{result: "unvalidated prose", extra: %{}},
                 job
               )

      refute_receive {:wrapper_argv, _, _, _}
      assert Results.for_run(run.run_id) == []
    end
  end

  test "missing or changed run routing cannot send selected jobs through the default adapter" do
    %{job: job} = launch()

    for meta <- [
          Map.delete(job.meta, "workflow_run"),
          Map.put(job.meta, "workflow_run", nil),
          Map.put(job.meta, "workflow_run", "missing-run")
        ] do
      changed = job |> Ecto.Changeset.change(meta: meta) |> Repo.update!()
      assert {:error, _} = ResultContract.launch_check(changed)
      assert {:cancel, _} = NodeJob.perform(changed)
      refute_receive {:wrapper_argv, _, _, _}
    end
  end

  test "sealed adapter options omit all caller session, tool, hook, plugin, environment and binary overrides" do
    opts =
      ExecutionPolicy.sealed_opts(
        model: "sonnet",
        effort: :low,
        max_budget_usd: 0.5,
        timeout: 10_000,
        resume: "other",
        session_observer: {self(), make_ref()},
        env: [{"UNTRUSTED", "1"}],
        binary: "/bad",
        tools: ["Bash"],
        plugin_dirs: ["/bad"],
        settings: "{}",
        mcp_config: ["bad"],
        dangerously_skip_permissions: true,
        max_turns: 99
      )

    assert opts[:model] == "sonnet"
    assert opts[:effort] == :low
    assert opts[:timeout] == 10_000
    assert opts[:max_turns] == 1
    assert opts[:tools] == [""]
    assert opts[:mcp_config] == []
    assert opts[:settings] == ~s({"disableAllHooks":true})

    for key <- [
          :resume,
          :session_observer,
          :env,
          :binary,
          :plugin_dirs,
          :dangerously_skip_permissions
        ],
        do: refute(Keyword.has_key?(opts, key))
  end

  defp definition(profile) do
    Workflow.new!(
      uid("tool-free-workflow"),
      [
        %Stage{
          name: :analyse,
          nodes: [
            %Node{
              name: :answer,
              prompt: "Use only supplied <%= @repo %> input",
              schema: %{"type" => "object"}
            }
          ]
        }
      ],
      model: "sonnet",
      effort: "low",
      execution_profile: profile
    )
  end

  defp launch do
    workflow = definition(ExecutionPolicy.profile())
    put_env!(:extra_workflows, %{workflow.name => workflow})
    {:ok, run} = Runner.launch(workflow.name, "acme/repo", max_budget_usd: 0.5)

    job =
      Repo.one!(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
        )
      )

    on_exit(fn ->
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))

      Results.delete_run(run.run_id)
      Repo.delete_all(from(r in Run.Row, where: r.run_id == ^run.run_id))
    end)

    %{run: run, job: job}
  end

  defp flag(args, name), do: Enum.at(args, Enum.find_index(args, &(&1 == name)) + 1)
end
