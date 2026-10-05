defmodule Custode.WorkflowRunnerTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Node
  alias Custode.Workflow.NodeJob
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner
  alias Custode.Workflow.Stage

  # The test env runs with no executing queues, so a node's job inserts and
  # sits there. That is exactly the seam these tests want: they assert what was
  # enqueued, then hand the runner the result the node WOULD have produced.

  setup do
    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))
    on_exit(fn -> Application.delete_env(:custode, :extra_workflows) end)
    :ok
  end

  defp node_fixture(name, prompt \\ "do <%= @repo %>") do
    %Node{name: name, prompt: prompt, schema: %{"type" => "object"}}
  end

  # mine (two nodes) -> merge (one) -> check (per_item)
  defp toy_workflow(name) do
    Workflow.new!(name, [
      %Stage{name: :mine, nodes: [node_fixture(:spec), node_fixture(:code)]},
      %Stage{
        name: :merge,
        nodes: [node_fixture(:merge, "merge <%= @repo %>\n<%= @digests %>")]
      },
      %Stage{
        name: :check,
        per_item: true,
        nodes: [node_fixture(:check, "check <%= @item %>")]
      }
    ])
  end

  defp register(workflow) do
    Application.put_env(:custode, :extra_workflows, %{workflow.name => workflow})
    workflow
  end

  defp jobs(run_id) do
    from(j in Oban.Job,
      where: j.worker == "Custode.Workflow.NodeJob",
      where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run_id,
      order_by: [asc: j.id]
    )
    |> Repo.all()
  end

  defp node_names(run_id), do: Enum.map(jobs(run_id), & &1.meta["node_name"])

  # the shape ObanClaude.structured/1 reads a --json-schema result out of
  defp result(structured, text \\ "ran") do
    %ClaudeWrapper.Result{result: text, extra: %{"structured_output" => structured}}
  end

  defp finish(run_id, node_name, structured) do
    job = Enum.find(jobs(run_id), &(&1.meta["node_name"] == node_name))
    refute is_nil(job), "no job enqueued for #{node_name}"
    Runner.node_finished(job.meta, result(structured))
  end

  test "terminal callbacks cannot overwrite failure identity or accepted sibling results" do
    workflow = register(toy_workflow(uid("fenced")))
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")
    [first, sibling] = jobs(run.run_id)
    Runner.node_finished(first.meta, result(%{"saved" => "first"}))
    failed = Runner.node_failed(sibling.meta, :first_failure)
    assert failed.failure_identity["node_name"] == sibling.meta["node_name"]
    assert failed.failure_identity["execution_generation"] == run.execution_generation
    assert failed.failure_identity["stage"] == "mine"

    Runner.node_finished(first.meta, result(%{"saved" => "overwritten"}))
    Runner.node_finished(sibling.meta, result(%{"late" => true}))
    Runner.node_failed(first.meta, :late_failure)
    assert Run.get(run.run_id) == failed
    assert [%{result: %{"saved" => "first"}}] = Results.for_run(run.run_id)
  end

  test "wrong generation and prior-stage callbacks are refused before persistence" do
    workflow = register(toy_workflow(uid("stale-generation")))
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")
    [first, sibling] = jobs(run.run_id)
    stale = Map.put(first.meta, "execution_generation", "another-generation")
    Runner.node_finished(stale, result(%{"wrong" => true}))

    Runner.node_finished(
      Map.put(first.meta, "args_hash", "wrong-input"),
      result(%{"wrong" => true})
    )

    Runner.node_failed(Map.put(first.meta, "callback_job_id", sibling.id), :wrong_job)
    Runner.node_failed(Map.delete(first.meta, "args_hash"), :missing_input_identity)
    Runner.node_failed(Map.put(first.meta, "callback_job_id", "not-a-job-id"), :malformed_job)
    Runner.node_failed(stale, :wrong_failure)
    assert Results.for_run(run.run_id) == []
    assert Run.get(run.run_id).status == "running"
    Runner.node_finished(first.meta, result(%{"items" => []}))
    Runner.node_finished(sibling.meta, result(%{"items" => []}))
    assert Run.get(run.run_id).stage == "merge"
    Runner.node_failed(first.meta, :late_old_stage_failure)
    assert Run.get(run.run_id).stage == "merge"
    assert Run.get(run.run_id).status == "running"
  end

  test "duplicate concurrent results keep the first accepted value" do
    workflow = register(toy_workflow(uid("first-result")))
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")
    first = hd(jobs(run.run_id))
    Runner.node_finished(first.meta, result(%{"value" => "accepted"}))

    1..8
    |> Task.async_stream(fn n -> Runner.node_finished(first.meta, result(%{"value" => n})) end)
    |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

    assert [%{result: %{"value" => "accepted"}}] = Results.for_run(run.run_id)
    Runner.node_failed(first.meta, :contradictory_failure)
    assert Run.get(run.run_id).status == "running"
  end

  test "definition changes stop advancement while the checklist retains launch order" do
    workflow = register(toy_workflow(uid("snapshot")))
    {:ok, run} = Runner.launch(workflow.name, "acme/repo")
    register(%{workflow | stages: Enum.reverse(workflow.stages)})
    assert {:error, :definition_changed} = Runner.advance(run.run_id)
    failed = Run.get(run.run_id)
    assert failed.error =~ "definition changed"
    assert Enum.map(Launch.checklist(failed), & &1.name) == ["mine", "merge", "check"]
    Application.delete_env(:custode, :extra_workflows)
    assert Enum.map(Launch.checklist(failed), & &1.state) == [:failed, :not_run, :not_run]
    assert Enum.all?(jobs(run.run_id), &(&1.state == "cancelled"))
  end

  describe "launch (#271)" do
    test "opens a run and enqueues exactly the first stage" do
      workflow = register(toy_workflow(uid("toy")))

      assert {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))
      assert run.status == "running"
      assert run.stage == "mine"
      assert run.workflow == workflow.name
      assert run.repo == "genagent/custode"

      # the merge node is NOT enqueued: stages are barriers
      assert node_names(run.run_id) == ["spec", "code"]
    end

    test "a definition the catalog cannot find again is refused, not half-run" do
      # a run resolves its definition from its own record on every advance, so
      # launching one nothing can look up would walk a stage and then stall
      orphan = toy_workflow(uid("orphan"))

      assert :error = Runner.launch(orphan.name, "genagent/custode")
      assert Enum.all?(Run.list(), &(&1.workflow != orphan.name))
    end

    test "the node's job carries the run identity and the node's schema" do
      workflow = register(toy_workflow(uid("toy")))
      {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))

      [spec | _] = jobs(run.run_id)

      assert spec.queue == "workflows"
      assert spec.meta["workflow_run"] == run.run_id
      assert spec.meta["stage"] == "mine"
      assert spec.meta["node_name"] == "spec"
      assert is_binary(spec.meta["args_hash"])
      # spend is attributable to the run, which is what the gate's estimate
      # (slice 2) calibrates against
      assert spec.meta["agent_id"] == "workflow-" <> run.run_id

      assert spec.args["json_schema"] == ~s({"type":"object"})
      # the prompt is RENDERED, not the template
      assert spec.args["prompt"] =~ "do genagent/custode"
    end

    test "named writing tools are pinned off, without claiming Bash or MCP confinement" do
      # pinned args win over a job's own args and are merged at perform time,
      # so a stored job cannot ask the writing tools back
      assert NodeJob.pinned_args()["disallowed_tools"] ==
               ["Write", "Edit", "NotebookEdit"]
    end
  end

  describe "the walk (#271)" do
    setup do
      workflow = register(toy_workflow(uid("toy")))
      {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))
      %{workflow: workflow, run: run}
    end

    test "a stage advances only when ALL its nodes have landed", %{run: run} do
      finish(run.run_id, "spec", %{"items" => [%{"title" => "a"}]})

      # one of two: the cursor stays put and nothing new is enqueued
      assert Run.get(run.run_id).stage == "mine"
      assert node_names(run.run_id) == ["spec", "code"]

      finish(run.run_id, "code", %{"items" => [%{"title" => "b"}]})

      assert Run.get(run.run_id).stage == "merge"
      assert node_names(run.run_id) == ["spec", "code", "merge"]
    end

    test "a downstream prompt carries the previous stage's digests", %{run: run} do
      finish(run.run_id, "spec", %{"items" => [%{"title" => "from spec"}]})
      finish(run.run_id, "code", %{"items" => [%{"title" => "from code"}]})

      merge = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == "merge"))

      assert merge.args["prompt"] =~ "### spec"
      assert merge.args["prompt"] =~ "from spec"
      assert merge.args["prompt"] =~ "### code"
      assert merge.args["prompt"] =~ "from code"
    end

    test "a per_item stage fans out one node per upstream item", %{run: run} do
      finish(run.run_id, "spec", %{"items" => []})
      finish(run.run_id, "code", %{"items" => []})

      finish(run.run_id, "merge", %{
        "items" => [%{"title" => "first"}, %{"title" => "second"}, %{"title" => "third"}]
      })

      assert Run.get(run.run_id).stage == "check"
      assert node_names(run.run_id) == ["spec", "code", "merge", "check_1", "check_2", "check_3"]

      check_2 = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == "check_2"))
      assert check_2.args["prompt"] =~ "second"
      refute check_2.args["prompt"] =~ "third"
    end

    test "the run completes when the last stage lands", %{run: run} do
      finish(run.run_id, "spec", %{"items" => []})
      finish(run.run_id, "code", %{"items" => []})
      finish(run.run_id, "merge", %{"items" => [%{"title" => "only"}]})
      finish(run.run_id, "check_1", %{"verdict" => "keep"})

      done = Run.get(run.run_id)
      assert done.status == "complete"
      assert is_nil(done.stage)
      refute is_nil(done.finished_at)
    end

    test "an empty fan-out cascades to completion and says so on the run", %{run: run} do
      finish(run.run_id, "spec", %{"items" => []})
      finish(run.run_id, "code", %{"items" => []})
      # the merge found nothing, so the per_item stage has nothing to fan over
      finish(run.run_id, "merge", %{"items" => []})

      done = Run.get(run.run_id)
      assert done.status == "complete"
      # a stage that quietly did nothing must not read like a stage with
      # nothing to do
      assert Enum.any?(done.notes, &(&1 =~ "check fanned out over 0 items"))
    end

    test "advance is idempotent -- it never re-enqueues a node in flight", %{run: run} do
      before = node_names(run.run_id)

      assert {:ok, _} = Runner.advance(run.run_id)
      assert {:ok, _} = Runner.advance(run.run_id)

      assert node_names(run.run_id) == before
    end

    test "resume walks a run whose last node landed while nothing was listening", %{run: run} do
      # both nodes' results are on the record but no callback ran (the app was
      # down when the stage barrier completed)
      for node <- ["spec", "code"] do
        job = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == node))

        Results.put(%{
          workflow_run: run.run_id,
          workflow: job.meta["workflow"],
          stage: job.meta["stage"],
          node_name: job.meta["node_name"],
          args_hash: job.meta["args_hash"],
          result: %{"items" => []}
        })
      end

      assert Run.get(run.run_id).stage == "mine"
      assert {:ok, _} = Runner.resume(run.run_id)
      assert Run.get(run.run_id).stage == "merge"
    end

    test "resume_all picks up every running run", %{run: run} do
      finish(run.run_id, "spec", %{"items" => []})
      finish(run.run_id, "code", %{"items" => []})

      resumed = Runner.resume_all()
      assert Enum.any?(resumed, fn {id, _result} -> id == run.run_id end)
    end
  end

  describe "results the runner did not expect (#271)" do
    setup do
      workflow = register(toy_workflow(uid("toy")))
      {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))
      %{run: run}
    end

    test "a node whose result missed its schema is stored as text and noted", %{run: run} do
      job = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == "spec"))

      # Already queued legacy work keeps its old prose fallback; no retroactive receipt.
      row = Repo.one!(from(r in Run.Row, where: r.run_id == ^run.run_id))
      context = row.context |> Jason.decode!() |> Map.delete("result_contract_version")
      row |> Ecto.Changeset.change(context: Jason.encode!(context)) |> Repo.update!()
      legacy_meta = Map.delete(job.meta, "result_contract")
      job |> Ecto.Changeset.change(meta: legacy_meta) |> Repo.update!()

      Runner.node_finished(legacy_meta, %ClaudeWrapper.Result{
        result: "prose, no schema",
        extra: %{}
      })

      [stored] = Results.for_stage(run.run_id, "mine")
      assert stored.result == %{"text" => "prose, no schema"}
      assert Enum.any?(Run.get(run.run_id).notes, &(&1 =~ "no schema-shaped result"))

      # and the stage still counts it as landed, so the run is not wedged
      finish(run.run_id, "code", %{"items" => []})
      assert Run.get(run.run_id).stage == "merge"
    end

    test "a terminally failed node fails the run, keeping the cursor", %{run: run} do
      job = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == "spec"))
      Runner.node_failed(job.meta, {:cancel, :rail_hit})

      failed = Run.get(run.run_id)
      assert failed.status == "failed"
      assert failed.error =~ "spec"
      # how far it got stays readable
      assert failed.stage == "mine"

      # and a failed run does not keep walking
      assert {:ok, %{status: "failed"}} = Runner.advance(run.run_id)
    end

    test "a terminal failure cancels every pending sibling for only its run" do
      workflow =
        register(
          Workflow.new!(uid("failure"), [
            %Stage{
              name: :fan_out,
              nodes:
                Enum.map(
                  [:failing, :available, :scheduled, :retryable],
                  &node_fixture/1
                )
            }
          ])
        )

      {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))

      {:ok, other} =
        Runner.launch(workflow.name, "genagent/custode", run_id: uid("other-run"))

      run_jobs = Map.new(jobs(run.run_id), &{&1.meta["node_name"], &1})

      set_job_state(run_jobs["failing"], "executing")
      set_job_state(run_jobs["scheduled"], "scheduled")
      set_job_state(run_jobs["retryable"], "retryable")

      # Duplicate terminal callbacks may race under future queue concurrency.
      # Both must return normally, leave siblings cancelled, and leave another
      # run untouched.
      results =
        [run_jobs["failing"].meta, run_jobs["failing"].meta]
        |> Task.async_stream(&Runner.node_failed(&1, {:cancel, :boom}),
          max_concurrency: 2,
          ordered: false
        )
        |> Enum.to_list()

      assert Enum.all?(results, &match?({:ok, %{status: "failed"}}, &1))

      states = Map.new(jobs(run.run_id), &{&1.meta["node_name"], &1.state})

      assert states == %{
               "failing" => "executing",
               "available" => "cancelled",
               "scheduled" => "cancelled",
               "retryable" => "cancelled"
             }

      assert Enum.all?(jobs(other.run_id), &(&1.state == "available"))
    end

    test "a report for a run that does not exist is ignored, not a crash" do
      assert :ok = Runner.node_finished(%{"node_name" => "x"}, result(%{}))
      assert :ok = Runner.node_failed(%{}, :whatever)
      assert {:error, :no_such_run} = Runner.advance("no-such-run")
    end
  end

  describe "the catalog (#271)" do
    test "backlog-sweep is defined and valid" do
      assert {:ok, sweep} = Catalog.fetch("backlog-sweep")
      assert :ok = Workflow.validate(sweep)

      assert Enum.map(sweep.stages, & &1.name) == [:mine, :merge, :verify, :draft, :critique]

      assert Enum.map(Workflow.stage(sweep, :mine).nodes, & &1.name) ==
               [:spec, :docs, :code, :issues, :gaps]

      # verify runs before draft: adversarial verification kills items before
      # any drafting effort is spent on them
      verify = Enum.find_index(sweep.stages, &(&1.name == :verify))
      draft = Enum.find_index(sweep.stages, &(&1.name == :draft))
      assert verify < draft

      # it fans out, so its node count is not knowable at launch
      assert Workflow.node_count(sweep) == :unknown
    end

    test "every stage feeding a per_item stage produces the items it fans over" do
      sweep = Catalog.fetch!("backlog-sweep")

      for {stage, index} <- Enum.with_index(sweep.stages),
          index > 0,
          stage.per_item do
        upstream = Enum.at(sweep.stages, index - 1)

        for node <- upstream.nodes do
          assert get_in(node.schema, ["properties", "items"]),
                 "#{node.name} feeds the per_item stage #{stage.name} but produces no items"
        end
      end
    end

    test "an unknown name is an :error, and fetch! says which" do
      assert :error = Catalog.fetch("nope")
      assert_raise ArgumentError, ~r/nope/, fn -> Catalog.fetch!("nope") end
      assert "backlog-sweep" in Catalog.names()
    end
  end

  defp set_job_state(job, state) do
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: state])
  end
end
