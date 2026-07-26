defmodule Custode.WorkflowLaunchTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.Feed
  alias Custode.Repo
  alias Custode.SpendLedger
  alias Custode.Workflow
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Node
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner
  alias Custode.Workflow.Stage

  setup do
    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(Feed.Entry)
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))
    on_exit(fn -> Application.delete_env(:custode, :extra_workflows) end)
    :ok
  end

  defp node_fixture(name), do: %Node{name: name, prompt: "do <%= @repo %>", schema: %{}}

  # two fixed nodes then one fixed node: a knowable four... three-node count
  defp fixed_workflow(name) do
    Workflow.new!(name, [
      %Stage{name: :mine, nodes: [node_fixture(:spec), node_fixture(:code)]},
      %Stage{name: :merge, nodes: [node_fixture(:merge)]}
    ])
  end

  # the same, plus a per_item stage: the count is a floor, not a total
  defp fanning_workflow(name) do
    Workflow.new!(name, [
      %Stage{name: :mine, nodes: [node_fixture(:spec), node_fixture(:code)]},
      %Stage{name: :merge, nodes: [node_fixture(:merge)]},
      %Stage{name: :check, per_item: true, nodes: [node_fixture(:check)]}
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

  defp result(structured) do
    %ClaudeWrapper.Result{result: "ran", extra: %{"structured_output" => structured}}
  end

  defp finish(run_id, node_name, structured \\ %{"ok" => true}) do
    job = Enum.find(jobs(run_id), &(&1.meta["node_name"] == node_name))
    refute is_nil(job), "no job enqueued for #{node_name}"
    Runner.node_finished(job.meta, result(structured))
  end

  defp events, do: Enum.map(Feed.tail(50), & &1["event"])

  describe "the estimate (#271 slice 2)" do
    test "prices a fixed workflow off the repo's observed per-turn cost" do
      workflow = register(fixed_workflow(uid("fixed")))
      repo = uid("owner/priced")

      # a prior run against this repo IS the observed history: its nodes were
      # booked under the run's spend agent id
      {:ok, prior} = Runner.launch(workflow.name, repo, run_id: uid("prior"))
      SpendLedger.record(Run.spend_agent_id(prior.run_id), 0.20)
      SpendLedger.record(Run.spend_agent_id(prior.run_id), 0.40)

      assert {:ok, estimate} = Launch.estimate(workflow.name, repo)
      assert estimate.known_nodes == 3
      refute estimate.fans_out
      assert estimate.basis == :observed
      assert estimate.sample == 2
      assert_in_delta estimate.per_node_usd, 0.30, 0.0001
      assert_in_delta estimate.floor_usd, 0.90, 0.0001
      assert_in_delta estimate.total_usd, 0.90, 0.0001
    end

    test "no ledger history falls back to the per-node cap and says so" do
      workflow = register(fixed_workflow(uid("fixed")))

      assert {:ok, estimate} = Launch.estimate(workflow.name, uid("owner/fresh"))
      assert estimate.basis == :default
      assert estimate.sample == 0
      assert estimate.per_node_usd == Application.fetch_env!(:custode, :max_budget_usd)
    end

    test "a fan-out has no total, only a floor" do
      workflow = register(fanning_workflow(uid("fanning")))

      assert {:ok, estimate} = Launch.estimate(workflow.name, uid("owner/fan"))
      # the per_item stage's node contributes nothing knowable
      assert estimate.known_nodes == 3
      assert estimate.fans_out
      assert estimate.total_usd == nil
      assert estimate.floor_usd > 0
    end

    test "an unknown workflow is refused rather than priced at zero" do
      assert {:error, :unknown_workflow} = Launch.estimate("no-such-workflow", "owner/repo")
    end
  end

  describe "the launch gate (#271 slice 2)" do
    test "proposing starts nothing -- no run, no job, just a standing gate" do
      workflow = register(fixed_workflow(uid("fixed")))

      assert {:ok, proposal} =
               Launch.propose(workflow.name, "owner/repo", why: "the board is dry")

      assert Run.list() == []
      assert [standing] = Launch.pending()
      assert standing["proposal"] == proposal.id
      assert standing["why"] == "the board is dry"
      assert standing["estimate"]["known_nodes"] == 3
      assert "workflow_launch_proposed" in events()
    end

    test "approving launches the run on the rail the card quoted" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 3.5)

      assert {:ok, run} = Launch.approve(proposal.id)
      assert run.status == "running"
      assert run.budget_usd == 3.5
      assert Enum.map(jobs(run.run_id), & &1.meta["node_name"]) == ["spec", "code"]

      # the gate is answered: it leaves the standing list and does not come back
      assert Launch.pending() == []
      assert {:error, :no_such_proposal} = Launch.approve(proposal.id)
    end

    test "rejecting leaves no run and closes the gate" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo")

      assert :ok = Launch.reject(proposal.id, "not now")
      assert Run.list() == []
      assert Launch.pending() == []
      assert "workflow_launch_rejected" in events()
    end
  end

  describe "the run budget rail (#271 slice 2)" do
    setup do
      workflow = register(fanning_workflow(uid("railed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
      {:ok, run} = Launch.approve(proposal.id)
      %{workflow: workflow, run: run}
    end

    test "a run under its rail keeps walking", %{run: run} do
      SpendLedger.record(Run.spend_agent_id(run.run_id), 0.10)
      finish(run.run_id, "spec")
      finish(run.run_id, "code")

      assert Run.get(run.run_id).status == "running"
      assert Run.get(run.run_id).stage == "merge"
    end

    test "crossing the rail parks the run and names what it did not run", %{run: run} do
      finish(run.run_id, "spec")
      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")

      parked = Run.get(run.run_id)
      assert parked.status == "budget_paused"
      # not `failed`: nothing went wrong, and the cursor stays where it stopped
      assert parked.stage == "merge"
      assert parked.error =~ "run budget rail hit"
      assert Enum.any?(parked.notes, &(&1 =~ "merge"))
      assert "workflow_budget_paused" in events()
    end

    test "parking cancels the stage's outstanding jobs rather than leaving them queued",
         %{run: run} do
      finish(run.run_id, "spec")
      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")

      merge = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == "merge"))
      # the merge node was never enqueued at all -- the rail is checked BEFORE
      # a stage is paid for
      assert is_nil(merge)
    end

    test "resuming on a raised rail enqueues exactly what the pause skipped", %{run: run} do
      finish(run.run_id, "spec")
      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")
      assert Run.get(run.run_id).status == "budget_paused"

      assert {:ok, resumed} = Launch.unpause(run.run_id, budget_usd: 5.0)
      assert resumed.status == "running"
      assert resumed.budget_usd == 5.0
      assert resumed.error == nil
      assert Enum.any?(jobs(run.run_id), &(&1.meta["node_name"] == "merge"))
    end

    test "resuming without raising the rail parks it again, it does not overrun", %{run: run} do
      finish(run.run_id, "spec")
      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")

      assert {:ok, again} = Launch.unpause(run.run_id)
      assert again.status == "budget_paused"
    end

    test "a run with no rail is unbounded (the iex path slice 1b already had)" do
      workflow = register(fixed_workflow(uid("unbounded")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))
      SpendLedger.record(Run.spend_agent_id(run.run_id), 99.0)

      finish(run.run_id, "spec")
      finish(run.run_id, "code")

      assert Run.get(run.run_id).status == "running"
    end

    test "resuming something that is not paused is refused", %{run: run} do
      assert {:error, :not_paused} = Launch.unpause(run.run_id)
      assert {:error, :no_such_run} = Launch.unpause("no-such-run")
    end
  end

  describe "feed entries and the checklist (#271 slice 2)" do
    test "a run records launch, each stage barrier, and the finish" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo")
      {:ok, run} = Launch.approve(proposal.id)

      finish(run.run_id, "spec")
      finish(run.run_id, "code")
      finish(run.run_id, "merge")

      assert Run.get(run.run_id).status == "complete"

      recorded = events()
      assert "workflow_launched" in recorded
      assert "workflow_complete" in recorded
      assert Enum.count(recorded, &(&1 == "workflow_stage_complete")) == 2
    end

    test "the checklist covers every stage of the DEFINITION, not just what ran" do
      workflow = register(fanning_workflow(uid("fanning")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))

      finish(run.run_id, "spec")

      assert [mine, merge, check] = Launch.checklist(Run.get(run.run_id))
      assert mine.name == :mine
      assert mine.state == :running
      assert Enum.map(mine.nodes, & &1.node_name) == ["spec"]
      assert merge.state == :pending
      # a stage the run has not reached is still listed: a run parked halfway
      # must not read as one that finished early
      assert check.state == :pending
      assert check.per_item
    end

    test "a completed run's stages are all done" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))

      finish(run.run_id, "spec")
      finish(run.run_id, "code")
      finish(run.run_id, "merge")

      assert Enum.all?(Launch.checklist(Run.get(run.run_id)), &(&1.state == :done))
    end

    test "a failed node fails the run and says so in the feed" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))

      [spec | _] = jobs(run.run_id)
      Runner.node_failed(spec.meta, {:error, :boom})

      assert Run.get(run.run_id).status == "failed"
      assert "workflow_failed" in events()
    end
  end

  describe "recent/1" do
    test "live runs sort before finished ones" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, done} = Runner.launch(workflow.name, "owner/repo", run_id: uid("done"))
      finish(done.run_id, "spec")
      finish(done.run_id, "code")
      finish(done.run_id, "merge")

      {:ok, live} = Runner.launch(workflow.name, "owner/repo", run_id: uid("live"))

      assert [first, second] = Launch.recent()
      assert first.run_id == live.run_id
      assert second.run_id == done.run_id
    end
  end
end
