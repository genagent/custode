defmodule Custode.WorkflowReportTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1, tmp_workspace!: 0]
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.Workflow
  alias Custode.Workflow.Catalog
  alias Custode.Workflow.Node
  alias Custode.Workflow.Report
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner
  alias Custode.Workflow.Stage

  setup do
    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))
    on_exit(fn -> Application.delete_env(:custode, :extra_workflows) end)
    :ok
  end

  # search (one node) -> write (one node whose result carries the markdown),
  # the deep-report shape with the fan-out and the prompts taken out
  defp reporting_workflow(name) do
    workflow =
      Workflow.new!(
        name,
        [
          %Stage{
            name: :search,
            nodes: [%Node{name: :look, prompt: "look at <%= @repo %>", schema: %{}}]
          },
          %Stage{
            name: :synthesis,
            nodes: [%Node{name: :report, prompt: "write <%= @digests %>", schema: %{}}]
          }
        ],
        report: %{node: :report, key: "report", filename: "report.md"}
      )

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

  defp finish(run_id, node_name, structured) do
    job = Enum.find(jobs(run_id), &(&1.meta["node_name"] == node_name))
    refute is_nil(job), "no job enqueued for #{node_name}"

    Runner.node_finished(job.meta, %ClaudeWrapper.Result{
      result: "ran",
      extra: %{"structured_output" => structured}
    })
  end

  # walk a run to completion, with the synthesis node returning `structured`
  defp run_to_completion(structured, opts \\ []) do
    workflow = reporting_workflow(uid("reporting"))
    dir = Keyword.get(opts, :artifact_dir, tmp_workspace!())

    {:ok, run} =
      Runner.launch(workflow.name, "genagent/custode",
        run_id: uid("run"),
        context: %{"artifact_dir" => dir}
      )

    finish(run.run_id, "look", %{"items" => []})
    finish(run.run_id, "report", structured)

    {Run.get(run.run_id), dir}
  end

  describe "writing the artifact (#275)" do
    test "a completed run writes its synthesis markdown to the artifact dir" do
      {run, dir} = run_to_completion(%{"title" => "t", "report" => "# Findings\n\nplain prose."})

      assert run.status == "complete"

      path = Path.join(dir, "report.md")
      assert File.read!(path) == "# Findings\n\nplain prose."

      # the row points at the file: this is the only reference to it, and what
      # the janitor reads before retiring the run
      assert Results.artifacts(run.run_id) == [path]
    end

    test "the run's notes and the feed both name what was written" do
      {run, dir} = run_to_completion(%{"report" => "# Findings"})

      assert run.notes == []

      entry =
        Custode.Feed.recent_by_event("workflow_report", limit: 20)
        |> Enum.find(&(&1["run"] == run.run_id))

      refute is_nil(entry), "no workflow_report feed entry"
      assert entry["artifact"] == Path.join(dir, "report.md")
      assert entry["summary"] =~ "report saved"
    end

    test "a synthesis node that returned no markdown notes it and still completes" do
      {run, dir} = run_to_completion(%{"title" => "t", "summary" => "s"})

      # the run did all its work; failing it would throw that away to punish
      # one bad last turn
      assert run.status == "complete"
      assert Results.artifacts(run.run_id) == []
      refute File.exists?(Path.join(dir, "report.md"))
      assert Enum.any?(run.notes, &(&1 =~ "no report written"))
    end

    test "an empty report reads as no report rather than an empty file" do
      {run, dir} = run_to_completion(%{"report" => "   \n"})

      refute File.exists?(Path.join(dir, "report.md"))
      assert Enum.any?(run.notes, &(&1 =~ "empty report"))
    end

    test "a workflow that declares no report writes nothing and notes nothing" do
      workflow = Custode.TestHelpers.workflow_fixture!(uid("plain"))

      {:ok, run} = Runner.launch(workflow.name, "genagent/custode", run_id: uid("run"))
      finish(run.run_id, "spec", %{"items" => []})
      finish(run.run_id, "code", %{"items" => []})
      finish(run.run_id, "merge", %{"items" => []})

      run = Run.get(run.run_id)
      assert run.status == "complete"
      assert Results.artifacts(run.run_id) == []
      refute Enum.any?(run.notes, &(&1 =~ "report"))
    end
  end

  describe "where the artifact lands (#275)" do
    test "a launch stamps an artifact dir under the data dir, not the repo checkout" do
      workflow = reporting_workflow(uid("reporting"))
      checkout = tmp_workspace!()

      {:ok, run} =
        Runner.launch(workflow.name, "genagent/custode",
          run_id: uid("run"),
          working_dir: checkout
        )

      dir = run.context["artifact_dir"]
      assert dir == Report.default_dir(run.run_id)
      refute String.starts_with?(Path.expand(dir), Path.expand(checkout) <> "/")
      assert Report.dir(run) == Path.expand(dir)
    end

    test "a run recorded before artifact dirs existed falls back to its working dir" do
      run = %{run_id: uid("run"), context: %{"working_dir" => "/tmp/somewhere"}}

      assert Report.dir(run) == "/tmp/somewhere"
    end

    test "the stamped dir survives a resume, so a rerun writes where the launch would have" do
      {run, dir} = run_to_completion(%{"report" => "# Findings"})

      assert Run.get(run.run_id).context["artifact_dir"] == dir
    end
  end

  describe "the deep-report catalog entry (#275)" do
    test "it is in the catalog and validates" do
      assert "deep-report" in Catalog.names()
      assert {:ok, workflow} = Catalog.fetch("deep-report")
      assert Workflow.validate(workflow) == :ok
    end

    test "its stages are the research shape: search, confirm per item, analyse, synthesis" do
      workflow = Catalog.fetch!("deep-report")

      assert Enum.map(workflow.stages, & &1.name) == [:search, :confirm, :analyse, :synthesis]
      assert Workflow.stage(workflow, :confirm).per_item
      refute Workflow.stage(workflow, :analyse).per_item
    end

    test "the search stage produces the items the confirm stage fans out over" do
      workflow = Catalog.fetch!("deep-report")

      for node <- Workflow.stage(workflow, :search).nodes do
        assert %{"properties" => %{"items" => _}} = node.schema
        assert "items" in node.schema["required"]
      end
    end

    test "confirming defaults to DROP, the other way round from backlog-sweep" do
      confirm = hd(Workflow.stage(Catalog.fetch!("deep-report"), :confirm).nodes)
      verify = hd(Workflow.stage(Catalog.fetch!("backlog-sweep"), :verify).nodes)

      assert confirm.schema["properties"]["verdict"]["enum"] == ["confirmed", "unconfirmed"]
      assert verify.schema["properties"]["verdict"]["enum"] == ["keep", "drop"]

      assert confirm.prompt =~ "default verdict is unconfirmed"
      assert verify.prompt =~ "default verdict is keep"
    end

    test "the report declaration points at the synthesis node's markdown" do
      workflow = Catalog.fetch!("deep-report")

      assert workflow.report == %{node: :report, key: "report", filename: "report.md"}
      assert "report" in hd(Workflow.stage(workflow, :synthesis).nodes).schema["required"]
    end

    test "a launch with no subject renders the repo, and one with a subject renders it" do
      prompt = hd(Workflow.stage(Catalog.fetch!("deep-report"), :search).nodes).prompt

      assert Runner.render(prompt, repo: "genagent/custode", context: %{}) =~ "genagent/custode"

      assert Runner.render(prompt,
               repo: "genagent/custode",
               context: %{"subject" => "durable queues"}
             ) =~ "durable queues"
    end

    test "every deep-report prompt renders with the bindings the runner supplies" do
      workflow = Catalog.fetch!("deep-report")

      for node <- Workflow.nodes(workflow) do
        rendered =
          Runner.render(node.prompt,
            repo: "genagent/custode",
            run: "run-1",
            workflow: workflow.name,
            stage: :search,
            node: to_string(node.name),
            digests: "(digests)",
            item: ~s({"claim": "x"}),
            context: %{}
          )

        assert rendered != ""
      end
    end
  end
end
