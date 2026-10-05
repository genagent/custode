defmodule Custode.WorkflowResultContractTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  alias Custode.{Repo, Workflow}
  alias Custode.Workflow.{Node, NodeJob, ResultContract, Results, RetryStatus, Run, Runner, Stage}

  @schema %{
    "type" => "object",
    "required" => ["value"],
    "additionalProperties" => false,
    "properties" => %{"value" => %{"type" => "integer", "minimum" => 1}}
  }
  @human %{kind: :operator, id: "result-contract-fixture"}

  setup do
    workflow =
      Workflow.new!(uid("result-contract"), [
        %Stage{
          name: :review,
          nodes: [
            %Node{name: :first, prompt: "first <%= @repo %>", schema: @schema},
            %Node{name: :second, prompt: "second <%= @repo %>", schema: @schema}
          ]
        }
      ])

    put_env!(:extra_workflows, %{workflow.name => workflow})
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id,
          order_by: [asc: j.id]
        )
      )

    on_exit(fn ->
      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
        )
      )

      Results.delete_run(run.run_id)
      Repo.delete_all(from(r in Run.Row, where: r.run_id == ^run.run_id))
    end)

    %{run: run, jobs: jobs}
  end

  test "actual worker callback retains a bound schema receipt without native claims", ctx do
    [first, _] = ctx.jobs
    assert :ok = ResultContract.launch_check(first)
    assert :ok = NodeJob.handle_result(result(%{"value" => 1}), first)
    [saved] = Results.for_run(ctx.run.run_id)
    assert {:error, :workflow_execution_not_current} = ResultContract.launch_check(first)
    assert saved.validation["state"] == "schema_validated"
    assert saved.validation["job_id"] == first.id
    assert saved.validation["callback_attempt"] == first.attempt
    assert saved.validation["native_identity"] == "unknown"
    assert saved.validation["physical_settlement"] == "unattested"
    assert saved.validation["contract"]["schema"] == @schema
    assert saved.validation["contract"]["launch_args_sha256"] == Results.args_hash(first.args)
    assert {:ok, diagnostic} = RetryStatus.read(@human, ctx.run.run_id)
    assert diagnostic.result_validation.schema_validated == 1
    refute diagnostic.retry_offered

    assert ResultContract.receipt_state(%{saved | result: %{"value" => 2}}, ctx.run) ==
             "legacy_or_unbound"

    assert ResultContract.receipt_state(
             %{
               saved
               | validation: %{
                   "state" => "schema_validated",
                   "version" => ResultContract.version(),
                   "contract" => []
                 }
             },
             ctx.run
           ) == "legacy_or_unbound"
  end

  test "new invalid output fails only its current stage and preserves accepted siblings", ctx do
    [first, second] = ctx.jobs
    NodeJob.handle_result(result(%{"value" => 1}), first)
    NodeJob.handle_result(result(%{"value" => "wrong"}), second)
    failed = Run.get(ctx.run.run_id)
    assert failed.status == "failed"
    assert failed.failure_identity["callback_job_id"] == second.id
    assert failed.failure_identity["result_validation"]["state"] == "invalid_structured_output"
    assert [%{node_name: "first", result: %{"value" => 1}}] = Results.for_run(ctx.run.run_id)
    NodeJob.handle_result(result(%{"value" => 2}), second)
    NodeJob.handle_result(result(%{"value" => 3}), first)
    assert Run.get(ctx.run.run_id) == failed
    assert [%{result: %{"value" => 1}}] = Results.for_run(ctx.run.run_id)
  end

  test "stored argument or contract changes refuse before execution and completion", ctx do
    [first, _] = ctx.jobs
    original = Run.get(ctx.run.run_id)

    mutations = [
      [args: Map.put(first.args, "prompt", "changed")],
      [args: Map.put(first.args, "max_budget_usd", 999)],
      [args: Map.put(first.args, "json_schema", "{}")],
      [meta: Map.delete(first.meta, "result_contract")],
      [meta: Map.put(first.meta, "result_contract", %{})],
      [meta: put_in(first.meta, ["result_contract", "pinned_policy_sha256"], "changed")]
    ]

    for mutation <- mutations do
      changed = first |> Ecto.Changeset.change(mutation) |> Repo.update!()
      assert {:error, :result_contract_changed_or_missing} = ResultContract.launch_check(changed)
      assert {:cancel, :result_contract_changed_or_missing} = NodeJob.perform(changed)
      NodeJob.handle_result(result(%{"value" => 1}), changed)
      assert Results.for_run(ctx.run.run_id) == []
      assert Run.get(ctx.run.run_id) == original
      changed |> Ecto.Changeset.change(args: first.args, meta: first.meta) |> Repo.update!()
    end
  end

  test "unsupported or malformed schema assertions never launch or issue a valid receipt" do
    for schema <- [
          Map.put(@schema, "oneOf", [%{"required" => ["missing"]}]),
          Map.put(@schema, "multipleOf", 3),
          Map.put(@schema, "$schema", "https://example.invalid/schema"),
          Map.put(@schema, "$schema", "http://json-schema.org/draft-04/schema#"),
          put_in(
            @schema,
            ["properties", "value", "$schema"],
            "https://json-schema.org/draft/2020-12/schema"
          ),
          Map.put(@schema, "properties", []),
          put_in(@schema, ["properties", "value", "type"], "unknown"),
          put_in(@schema, ["properties", "value", "minLength"], 2)
        ] do
      workflow =
        Workflow.new!(uid("unsupported-schema"), [
          %Stage{name: :review, nodes: [%Node{name: :check, prompt: "check", schema: schema}]}
        ])

      put_env!(:extra_workflows, %{workflow.name => workflow})
      {:ok, run} = Runner.launch(workflow.name, "acme/repo")

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

      assert {:error, :unsupported_result_schema} = ResultContract.launch_check(job)
      assert {:cancel, :unsupported_result_schema} = NodeJob.perform(job)

      assert {:error, %{"state" => "schema_validation_unavailable"}} =
               ResultContract.validate(run, job, %{"value" => 1}, job.meta)

      NodeJob.handle_result(result(%{"value" => 1}), job)

      assert Run.get(run.run_id).status == "failed"
      assert Run.get(run.run_id).error =~ "unsupported_result_schema"

      assert Results.for_run(run.run_id) == []
    end
  end

  test "a rebuilt job contract cannot replace the captured definition or input identity", ctx do
    [first, _] = ctx.jobs
    args = Map.put(first.args, "json_schema", "{}")

    meta =
      Map.put(first.meta, "result_contract", ResultContract.capture(ctx.run, args, first.meta))

    changed = first |> Ecto.Changeset.change(args: args, meta: meta) |> Repo.update!()
    assert {:error, :result_contract_changed_or_missing} = ResultContract.launch_check(changed)
    NodeJob.handle_result(result(%{}), changed)
    assert Results.for_run(ctx.run.run_id) == []
    assert Run.get(ctx.run.run_id).status == "running"
  end

  test "an old job attempt callback cannot fail the current stage", ctx do
    [first, _] = ctx.jobs
    stale = first.meta |> Map.put("callback_job_id", first.id) |> Map.put("callback_attempt", 999)
    before = Run.get(ctx.run.run_id)
    Runner.node_finished(stale, result(%{"value" => "invalid"}))
    Runner.node_failed(stale, :old_attempt)
    assert Run.get(ctx.run.run_id) == before
    assert Results.for_run(ctx.run.run_id) == []
  end

  test "stale generation, terminal run and attempt redelivery never relaunch", ctx do
    [first, _] = ctx.jobs

    assert {:error, _} =
             ResultContract.launch_check(%{
               first
               | meta: Map.put(first.meta, "execution_generation", "old")
             })

    assert {:error, :workflow_execution_not_current} =
             ResultContract.launch_check(%{first | attempt: 2})

    Run.fail(ctx.run.run_id, "fixture failure")
    assert {:error, :workflow_execution_not_current} = ResultContract.launch_check(first)
    NodeJob.handle_result(result(%{"value" => 1}), first)
    assert Results.for_run(ctx.run.run_id) == []
  end

  test "legacy queued work retains completion behavior but never gains a validation receipt",
       ctx do
    [first, _] = ctx.jobs
    row = Repo.one!(from(r in Run.Row, where: r.run_id == ^ctx.run.run_id))
    context = ctx.run.context |> Map.delete("result_contract_version") |> Jason.encode!()
    row |> Ecto.Changeset.change(context: context) |> Repo.update!()

    legacy =
      first
      |> Ecto.Changeset.change(meta: Map.delete(first.meta, "result_contract"))
      |> Repo.update!()

    assert :ok = ResultContract.launch_check(legacy)
    NodeJob.handle_result(%ClaudeWrapper.Result{result: "legacy prose", extra: %{}}, legacy)
    [saved] = Results.for_run(ctx.run.run_id)
    assert saved.result == %{"text" => "legacy prose"}
    assert saved.validation == nil
    assert {:ok, status} = RetryStatus.read(@human, ctx.run.run_id)
    assert status.result_validation.legacy_or_unbound == 1
    refute status.retry_offered
  end

  defp result(payload), do: %ClaudeWrapper.Result{extra: %{"structured_output" => payload}}
end
