defmodule Custode.WorkflowExecutionObservationTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.{Janitor, Repo, Workflow}

  alias Custode.Workflow.{
    ClaudeRunner,
    ExecutionObservation,
    Node,
    NodeJob,
    Results,
    RetryStatus,
    Run,
    Runner,
    Stage
  }

  alias ExecutionObservation.Row

  setup do
    old_runner = Application.fetch_env(:claude_wrapper, :runner)
    old_binary = System.get_env("CLAUDE_CLI")
    directory = Path.join(System.tmp_dir!(), uid("runner-observation"))
    File.mkdir_p!(directory)
    binary = Path.join(directory, "fake-cli")

    fixture(
      binary,
      "printf '%s' '{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"private output\",\"structured_output\":{\"value\":7}}'"
    )

    Application.put_env(:claude_wrapper, :runner, ClaudeRunner)
    System.put_env("CLAUDE_CLI", binary)

    on_exit(fn ->
      restore(:claude_wrapper, :runner, old_runner)

      if old_binary,
        do: System.put_env("CLAUDE_CLI", old_binary),
        else: System.delete_env("CLAUDE_CLI")

      File.rm_rf!(directory)
    end)

    %{binary: binary, directory: directory}
  end

  test "actual selected worker and released builder retain exact private command and truthful return",
       ctx do
    %{run: run, job: job} = launch()
    assert :ok = NodeJob.perform(job)
    row = row!(run)
    assert row.job_id == job.id and row.job_attempt == 1
    assert row.binding["execution_generation"] == run.execution_generation
    assert row.binding["result_contract_sha256"] == Results.args_hash(job.meta["result_contract"])
    assert row.request["binary"] == ctx.binary
    assert Enum.take(row.request["argv"], -2) == ["--", job.args["prompt"]]
    assert flag(row.request["argv"], "--tools") == ""
    assert flag(row.request["argv"], "--setting-sources") == ""
    assert flag(row.request["argv"], "--permission-mode") == "plan"
    assert row.request["command_options"]["cd"] == job.args["working_dir"]
    assert row.request["timeout_ms"] == 900_000
    assert row.request["physical_settlement"] == "unattested"
    assert row.request_sha256 == Results.args_hash(row.request)
    assert row.transport_return["kind"] == "exit"
    assert row.transport_return["exit_code"] == 0
    assert row.transport_return["physical_settlement"] == "unattested"
    assert [%{validation: %{"state" => "schema_validated"}}] = Results.for_run(run.run_id)
    assert Run.get(run.run_id).status == "complete"
    assert ExecutionObservation.scope() == nil

    summary = ExecutionObservation.summary(run.run_id)
    assert summary.transport_returns == 1 and summary.unknown_returns == 0
    encoded = Jason.encode!(summary)
    refute encoded =~ job.args["prompt"]
    refute encoded =~ ctx.binary
    refute encoded =~ "private output"
    refute encoded =~ "command_options"

    human = %{id: "observation-test", kind: :operator}
    assert {:ok, status} = RetryStatus.read(human, run.run_id)
    assert status.runner_observations == summary
    refute status.retry_offered
  end

  test "ordinary and legacy workers delegate unchanged and produce no selected observation" do
    %{run: run, job: job} = launch(nil)
    assert :ok = NodeJob.perform(job)
    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
    assert [%{result: %{"value" => 7}}] = Results.for_run(run.run_id)

    assert {:ok, {"ordinary", 0}} =
             ClaudeRunner.run("/bin/sh", ["-c", "printf ordinary"], [], 2_000)

    assert Repo.aggregate(Row, :count) == 0
  end

  test "precontract queued default work retains legacy completion without acquiring observations" do
    %{run: run, job: job} = launch(nil)
    row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))

    row
    |> Ecto.Changeset.change(
      context: Jason.encode!(Map.delete(run.context, "result_contract_version"))
    )
    |> Repo.update!()

    legacy =
      job
      |> Ecto.Changeset.change(meta: Map.delete(job.meta, "result_contract"))
      |> Repo.update!()

    assert :ok = NodeJob.perform(legacy)
    assert [%{result: %{"value" => 7}, validation: nil}] = Results.for_run(run.run_id)
    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
  end

  test "observed and streaming delegation preserve stdout observers and existing transport behavior" do
    parent = self()

    observe = fn line ->
      send(parent, {:line, line})
      :observed
    end

    assert {:ok, {"one\ntwo\n", 0, ""}} =
             ClaudeRunner.run_observed(
               "/bin/sh",
               ["-c", "printf 'one\ntwo\n'"],
               [],
               2_000,
               observe
             )

    assert_receive {:line, "one"}
    refute_receive {:line, "two"}

    assert ["one", "two"] =
             ClaudeRunner.stream_lines("/bin/sh", ["-c", "printf 'one\ntwo\n'"], [], 2_000)
             |> Enum.to_list()

    assert Repo.aggregate(Row, :count) == 0
  end

  test "actual spawn refusal preserves the observed runner error without inventing a successful spawn",
       ctx do
    %{run: run, job: job} = launch()
    System.put_env("CLAUDE_CLI", Path.join(ctx.directory, "absent-binary"))
    refute NodeJob.perform(job) == :ok
    assert row!(run).transport_return["kind"] == "error"
    assert row!(run).transport_return["physical_settlement"] == "unattested"
    assert Run.get(run.run_id).status == "failed"
    assert Results.for_run(run.run_id) == []
  end

  test "actual nonzero transport exit remains separate from parsed workflow success", ctx do
    %{run: run, job: job} = launch()
    fixture(ctx.binary, "printf 'private error'; exit 7")
    refute NodeJob.perform(job) == :ok
    assert row!(run).transport_return["kind"] == "exit"
    assert row!(run).transport_return["exit_code"] == 7
    assert Run.get(run.run_id).status == "failed"
    assert Results.for_run(run.run_id) == []
    refute Jason.encode!(ExecutionObservation.summary(run.run_id)) =~ "private error"
  end

  test "stale stored inputs, generation, attempt and job identity refuse before a request" do
    %{run: run, job: job} = launch()

    for changed <- [
          %{job | id: -1},
          %{job | worker: "ObanClaude.Agent.Job"},
          %{job | attempt: 0},
          %{job | args: Map.put(job.args, "prompt", "changed private prompt")},
          %{job | meta: Map.put(job.meta, "execution_generation", "stale")}
        ] do
      assert {:error, :unbound_runner_execution} = request(changed)
    end

    stored = Repo.get!(Oban.Job, job.id)
    stored |> Ecto.Changeset.change(attempt: 2) |> Repo.update!()
    assert {:error, :unbound_runner_execution} = request(job)

    stored
    |> Ecto.Changeset.change(args: Map.put(job.args, "prompt", "changed"))
    |> Repo.update!()

    assert {:error, :unbound_runner_execution} = request(job)
    stored |> Ecto.Changeset.change(args: job.args, attempt: 1) |> Repo.update!()

    row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))
    row |> Ecto.Changeset.change(execution_generation: "new-generation") |> Repo.update!()
    assert {:error, :unbound_runner_execution} = request(job)
    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
  end

  test "substituted command limits, prompt, destination and environment refuse before delegation" do
    %{run: run, job: job} = launch()

    ExecutionObservation.with_job(job, fn ->
      for {argv, opts, timeout} <- [
            {["--", "other private prompt"], [cd: job.args["working_dir"]], 900_000},
            {["--", job.args["prompt"]], [cd: "/other-directory"], 900_000},
            {["--", job.args["prompt"]], [cd: job.args["working_dir"]], 10_000},
            {["--", job.args["prompt"]],
             [cd: job.args["working_dir"], env: [{"SECRET", "private secret"}]], 900_000}
          ] do
        assert {:error, :unbound_runner_execution} =
                 ExecutionObservation.request("/fixture", argv, opts, timeout)
      end
    end)

    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
  end

  test "oversized private requests refuse before persistence or transport delegation", ctx do
    %{run: run, job: job} = launch()
    marker = Path.join(ctx.directory, "must-not-start")
    fixture(ctx.binary, "printf started > '" <> marker <> "'")
    tail = ["--", job.args["prompt"]]

    ExecutionObservation.with_job(job, fn ->
      for argv <- [
            List.duplicate("argument", 255) ++ tail,
            [String.duplicate("x", 1_048_576)] ++ tail,
            [String.duplicate("\\", 600_000)] ++ tail
          ] do
        assert {:error, {:io, :workflow_observation_unavailable}} =
                 ClaudeRunner.run(ctx.binary, argv, [cd: job.args["working_dir"]], 900_000)
      end
    end)

    refute File.exists?(marker)
    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
  end

  test "selected alternate transports cannot bypass one-shot observation fencing" do
    %{run: run, job: job} = launch()

    ExecutionObservation.with_job(job, fn ->
      assert {:error, {:io, :unsupported_selected_transport}} =
               ClaudeRunner.run_observed("/bin/false", [], [], 900_000, fn _ ->
                 raise "not called"
               end)

      assert_raise ArgumentError, "selected workflow requires the one-shot transport", fn ->
        ClaudeRunner.stream_lines("/bin/false", [], [], 900_000)
      end
    end)

    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
  end

  test "first request and return are immutable and foreign owner tokens cannot attach returns" do
    %{run: run, job: job} = launch()

    token =
      ExecutionObservation.with_job(job, fn ->
        {:ok, token} = command_request(job)
        original = row!(run)
        assert {:error, :runner_already_requested} = command_request(job)
        assert {:error, :conflicting_runner_request} = command_request(job, "/different-binary")
        assert :ok = ExecutionObservation.returned(token, {:ok, {"private", 0}})
        first = row!(run)
        assert :ok = ExecutionObservation.returned(token, {:ok, {"private", 0}})

        assert {:error, :conflicting_transport_return} =
                 ExecutionObservation.returned(token, {:error, :timeout})

        assert row!(run) == first
        assert first.request == original.request and first.requested_at == original.requested_at
        token
      end)

    assert {:error, :unbound_transport_return} =
             ExecutionObservation.returned(token, {:error, :timeout})

    assert ExecutionObservation.scope() == nil
  end

  test "exceptions clear invocation scope and leave return unknown" do
    %{run: run, job: job} = launch()

    assert_raise RuntimeError, "private fixture exception", fn ->
      ExecutionObservation.with_job(job, fn ->
        assert {:ok, _token} = command_request(job)
        raise "private fixture exception"
      end)
    end

    assert ExecutionObservation.scope() == nil
    assert is_nil(row!(run).transport_return)
    assert ExecutionObservation.summary(run.run_id).unknown_returns == 1
    assert Results.for_run(run.run_id) == []
  end

  test "killed actual worker leaves a durable request and no invented return", ctx do
    %{run: run, job: job} = launch()
    marker = Path.join(ctx.directory, "started")
    fixture(ctx.binary, "printf started > '" <> marker <> "'; exec /bin/sleep 5")
    {pid, ref} = spawn_monitor(fn -> NodeJob.perform(job) end)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
    eventually(fn -> assert File.exists?(marker) end)
    assert row!(run).transport_return == nil
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert row!(run).transport_return == nil
    assert ExecutionObservation.summary(run.run_id).unknown_returns == 1
    assert Results.for_run(run.run_id) == []
    assert Run.get(run.run_id).status == "running"
  end

  test "late transport return remains bound to its captured invocation without changing the current run" do
    %{run: run, job: job} = launch()

    ExecutionObservation.with_job(job, fn ->
      {:ok, token} = command_request(job)
      row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))
      row |> Ecto.Changeset.change(execution_generation: "new-generation") |> Repo.update!()
      assert :ok = ExecutionObservation.returned(token, {:ok, {"late private output", 0}})
    end)

    assert row!(run).execution_generation == run.execution_generation
    assert row!(run).transport_return["kind"] == "exit"
    assert Run.get(run.run_id).execution_generation == "new-generation"
    assert Results.for_run(run.run_id) == []
  end

  test "transport timeout and spawn errors retain only available facts and no private reason values" do
    %{run: run, job: job} = launch()

    ExecutionObservation.with_job(job, fn ->
      {:ok, token} = command_request(job)
      assert :ok = ExecutionObservation.returned(token, {:error, :timeout})
    end)

    assert row!(run).transport_return == %{
             "kind" => "timeout",
             "detailed_timeout_result" => "unavailable",
             "physical_settlement" => "unattested"
           }

    %{run: other, job: other_job} = launch()

    ExecutionObservation.with_job(other_job, fn ->
      {:ok, token} = command_request(other_job)

      assert :ok =
               ExecutionObservation.returned(
                 token,
                 {:error, {:spawn, "private environment secret"}}
               )
    end)

    refute Jason.encode!(row!(other).transport_return) =~ "private environment secret"
  end

  test "bounded summary is truncated and janitor retires observations only with finished retained runs" do
    %{run: run, job: job} = launch()
    assert {:ok, _} = request(job)
    original = row!(run)

    for n <- 1..100 do
      Repo.insert!(%{original | id: uid("observation"), job_id: original.job_id + n})
    end

    assert %{delegation_requests: 100, truncated: true} = ExecutionObservation.summary(run.run_id)
    old = DateTime.add(DateTime.utc_now(), -100, :day)
    row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))
    row |> Ecto.Changeset.change(started_at: old) |> Repo.update!()
    put_env!(:janitor, workflow_runs_days: 90)
    assert :ok = Janitor.perform(%Oban.Job{})
    assert Repo.aggregate(from(o in Row, where: o.workflow_run == ^run.run_id), :count) == 101
    row |> Ecto.Changeset.change(status: "failed", finished_at: old) |> Repo.update!()
    assert :ok = Janitor.perform(%Oban.Job{})
    assert ExecutionObservation.summary(run.run_id).delegation_requests == 0
    assert Run.get(run.run_id) == nil
  end

  defp launch(profile \\ "custode.workflow_tool_free.v1") do
    definition =
      Workflow.new!(
        uid("observed-workflow"),
        [
          %Stage{
            name: :analyse,
            nodes: [
              %Node{
                name: :answer,
                prompt: "Private supplied <%= @repo %> input",
                schema: %{
                  "type" => "object",
                  "properties" => %{"value" => %{"type" => "integer"}},
                  "required" => ["value"]
                }
              }
            ]
          }
        ],
        model: "sonnet",
        effort: "low",
        execution_profile: profile
      )

    put_env!(:extra_workflows, %{definition.name => definition})
    {:ok, run} = Runner.launch(definition.name, uid("private/repo"), max_budget_usd: 0.5)

    job =
      Repo.one!(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
        )
      )

    job = job |> Ecto.Changeset.change(state: "executing", attempt: 1) |> Repo.update!()

    on_exit(fn ->
      ExecutionObservation.delete_run(run.run_id)
      Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))
      Results.delete_run(run.run_id)
      Repo.delete_all(from(r in Run.Row, where: r.run_id == ^run.run_id))
    end)

    %{run: run, job: job}
  end

  defp request(job), do: ExecutionObservation.with_job(job, fn -> command_request(job) end)

  defp command_request(job, binary \\ "/fixture-binary"),
    do:
      ExecutionObservation.request(
        binary,
        ["--", job.args["prompt"]],
        [cd: job.args["working_dir"], stderr_to_stdout: true],
        job.args["timeout"]
      )

  defp row!(run), do: Repo.one!(from(row in Row, where: row.workflow_run == ^run.run_id))

  defp fixture(binary, command) do
    File.write!(binary, "#!/bin/sh\n" <> command <> "\n")
    File.chmod!(binary, 0o755)
  end

  defp flag(args, key), do: Enum.at(args, Enum.find_index(args, &(&1 == key)) + 1)
  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)
end
