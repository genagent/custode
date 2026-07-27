defmodule Custode.WorkflowTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1]

  alias Custode.Workflow
  alias Custode.Workflow.Node
  alias Custode.Workflow.Results
  alias Custode.Workflow.Stage

  defp node_fixture(name, opts \\ []) do
    %Node{
      name: name,
      prompt: "mine <%= @repo %>",
      schema: %{"type" => "object"},
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort)
    }
  end

  defp stage_fixture(name, nodes, opts \\ []) do
    %Stage{
      name: name,
      nodes: nodes,
      per_item: Keyword.get(opts, :per_item, false),
      model: Keyword.get(opts, :model),
      effort: Keyword.get(opts, :effort)
    }
  end

  describe "the definition (#271)" do
    test "a well-formed workflow validates" do
      assert {:ok, workflow} =
               Workflow.new("backlog-sweep", [
                 stage_fixture(:mine, [node_fixture(:spec), node_fixture(:code)]),
                 stage_fixture(:merge, [node_fixture(:merge)], effort: "high"),
                 stage_fixture(:verify, [node_fixture(:verify)], per_item: true)
               ])

      assert workflow.name == "backlog-sweep"
      assert Enum.map(Workflow.nodes(workflow), & &1.name) == [:spec, :code, :merge, :verify]
      assert Workflow.stage(workflow, :merge).effort == "high"
      assert Workflow.stage(workflow, :nope) == nil
    end

    test "a workflow needs a name and at least one stage" do
      assert {:error, reason} = Workflow.new("", [stage_fixture(:mine, [node_fixture(:spec)])])
      assert reason =~ "name"

      assert {:error, reason} = Workflow.new("empty", [])
      assert reason =~ "at least one stage"
    end

    test "node names must be unique workflow-wide, not just per stage" do
      # they key the results table, so a repeat would collide across stages
      assert {:error, reason} =
               Workflow.new("dupes", [
                 stage_fixture(:mine, [node_fixture(:report)]),
                 stage_fixture(:merge, [node_fixture(:report)])
               ])

      assert reason =~ "duplicate node name :report"
    end

    test "stage names must be unique" do
      assert {:error, reason} =
               Workflow.new("dupes", [
                 stage_fixture(:mine, [node_fixture(:a)]),
                 stage_fixture(:mine, [node_fixture(:b)])
               ])

      assert reason =~ "duplicate stage name :mine"
    end

    test "a per_item stage carries exactly one node and cannot come first" do
      assert {:error, reason} =
               Workflow.new("fanout", [
                 stage_fixture(:verify, [node_fixture(:a)], per_item: true)
               ])

      assert reason =~ "first stage cannot be per_item"

      assert {:error, reason} =
               Workflow.new("fanout", [
                 stage_fixture(:mine, [node_fixture(:spec)]),
                 stage_fixture(:verify, [node_fixture(:a), node_fixture(:b)], per_item: true)
               ])

      assert reason =~ "exactly one node"
    end

    test "a node needs a prompt template and a schema" do
      assert {:error, reason} =
               Workflow.new("bad", [
                 stage_fixture(:mine, [%Node{name: :spec, prompt: "", schema: %{}}])
               ])

      assert reason =~ "prompt"

      assert {:error, reason} =
               Workflow.new("bad", [
                 stage_fixture(:mine, [%Node{name: :spec, prompt: "go", schema: "object"}])
               ])

      assert reason =~ "schema"
    end

    test "new! raises the same reason" do
      assert_raise ArgumentError, ~r/duplicate node name/, fn ->
        Workflow.new!("dupes", [
          stage_fixture(:mine, [node_fixture(:report)]),
          stage_fixture(:merge, [node_fixture(:report)])
        ])
      end
    end

    test "node_count is :unknown once a stage fans out" do
      fixed =
        Workflow.new!("fixed", [
          stage_fixture(:mine, [node_fixture(:spec), node_fixture(:code)]),
          stage_fixture(:merge, [node_fixture(:merge)])
        ])

      assert Workflow.node_count(fixed) == 3

      fanout =
        Workflow.new!("fanout", [
          stage_fixture(:mine, [node_fixture(:spec)]),
          stage_fixture(:verify, [node_fixture(:verify)], per_item: true)
        ])

      assert Workflow.node_count(fanout) == :unknown
    end

    test "model and effort cascade node over stage over workflow" do
      stage = stage_fixture(:mine, [node_fixture(:spec, effort: "max")], model: "sonnet")

      workflow =
        Workflow.new!("cascade", [stage, stage_fixture(:merge, [node_fixture(:merge)])],
          model: "opus",
          effort: "low"
        )

      [spec, merge] = Workflow.nodes(workflow)

      # the node's effort wins, the stage's model wins, the workflow supplies
      # neither where a nearer one exists
      assert Workflow.settings(workflow, stage, spec) == %{model: "sonnet", effort: "max"}

      assert Workflow.settings(workflow, Workflow.stage(workflow, :merge), merge) ==
               %{model: "opus", effort: "low"}
    end
  end

  describe "node results (#271)" do
    setup do
      %{run: uid("run")}
    end

    test "a result round-trips and is keyed by run + node + args hash", %{run: run} do
      hash = Results.args_hash(%{repo: "genagent/custode"})

      stored =
        Results.put(%{
          workflow_run: run,
          workflow: "backlog-sweep",
          stage: :mine,
          node_name: :spec,
          args_hash: hash,
          result: %{"findings" => ["a", "b"]}
        })

      assert stored.result == %{"findings" => ["a", "b"]}
      assert stored.stage == "mine"

      fetched = Results.fetch(run, :spec, hash)
      assert fetched.result == %{"findings" => ["a", "b"]}
      assert fetched.workflow == "backlog-sweep"
      assert fetched.artifact == nil

      # a different args hash is a different node result: this is what makes
      # an edited upstream prompt re-run the node instead of reusing it
      assert Results.fetch(run, :spec, Results.args_hash(%{repo: "other"})) == nil
      assert Results.fetch(uid("other-run"), :spec, hash) == nil
    end

    test "putting the same key twice replaces rather than accumulates", %{run: run} do
      hash = Results.args_hash(%{repo: "genagent/custode"})

      attrs = %{
        workflow_run: run,
        workflow: "backlog-sweep",
        stage: :mine,
        node_name: :spec,
        args_hash: hash,
        result: %{"findings" => ["first"]}
      }

      Results.put(attrs)

      Results.put(
        Map.merge(attrs, %{result: %{"findings" => ["second"]}, artifact: "reports/spec.md"})
      )

      assert [only] = Results.for_run(run)
      assert only.result == %{"findings" => ["second"]}
      assert only.artifact == "reports/spec.md"
    end

    test "a run's results read back by run and by stage, oldest first", %{run: run} do
      for {stage, node} <- [{:mine, :spec}, {:mine, :code}, {:merge, :merge}] do
        Results.put(%{
          workflow_run: run,
          workflow: "backlog-sweep",
          stage: stage,
          node_name: node,
          args_hash: Results.args_hash(%{node: node}),
          result: %{"node" => to_string(node)}
        })
      end

      assert Enum.map(Results.for_run(run), & &1.node_name) == ~w(spec code merge)
      assert Enum.map(Results.for_stage(run, :mine), & &1.node_name) == ~w(spec code)
      assert Results.for_stage(run, :verify) == []
    end

    test "artifacts/1 names the run's report files and skips the nodes with none", %{run: run} do
      for {node, artifact} <- [
            {:spec, "reports/spec.md"},
            {:code, nil},
            {:merge, "reports/all.md"}
          ] do
        Results.put(%{
          workflow_run: run,
          workflow: "backlog-sweep",
          stage: :mine,
          node_name: node,
          args_hash: Results.args_hash(%{node: node}),
          result: %{},
          artifact: artifact
        })
      end

      assert Results.artifacts(run) == ["reports/spec.md", "reports/all.md"]
      assert Results.artifacts(uid("run")) == []
    end

    test "delete_run leaves nothing behind", %{run: run} do
      keep = uid("run")

      for target <- [run, keep] do
        Results.put(%{
          workflow_run: target,
          workflow: "backlog-sweep",
          stage: :mine,
          node_name: :spec,
          args_hash: Results.args_hash(%{}),
          result: %{}
        })
      end

      assert Results.delete_run(run) == 1
      assert Results.for_run(run) == []
      assert length(Results.for_run(keep)) == 1
    end

    test "args_hash ignores key order and distinguishes real differences" do
      assert Results.args_hash(%{a: 1, b: %{c: 2, d: 3}}) ==
               Results.args_hash(%{b: %{d: 3, c: 2}, a: 1})

      # string and atom keys name the same argument
      assert Results.args_hash(%{"a" => 1}) == Results.args_hash(%{a: 1})

      refute Results.args_hash(%{a: 1}) == Results.args_hash(%{a: 2})
      refute Results.args_hash(%{digest: ["x"]}) == Results.args_hash(%{digest: ["x", "y"]})
    end
  end
end
