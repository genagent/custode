defmodule Custode.WorkflowLaunchTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.Feed
  alias Custode.Repo
  alias Custode.SpendLedger
  alias Custode.Workflow
  alias Custode.Workflow.Launch
  alias Custode.Workflow.Node
  alias Custode.Workflow.ResultContract
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run
  alias Custode.Workflow.Runner
  alias Custode.Workflow.Stage

  setup do
    previous_workflows = Application.get_env(:custode, :extra_workflows)
    Repo.delete_all(Results.Result)
    Repo.delete_all(Run.Row)
    Repo.delete_all(Feed.Entry)
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"))

    on_exit(fn ->
      if previous_workflows,
        do: Application.put_env(:custode, :extra_workflows, previous_workflows),
        else: Application.delete_env(:custode, :extra_workflows)

      # A standing proposal and a parked run are needs-you signals now (#447),
      # so one left behind shows up in every later test that reads the inbox,
      # the chip or the console.
      Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'workflow_%'")
      Repo.delete_all(Results.Result)
      Repo.delete_all(Run.Row)
    end)

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
      assert {:ok, replay} = Launch.approve(proposal.id)
      assert replay.run_id == run.run_id
      assert length(jobs(run.run_id)) == 2
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

  describe "exact launch decisions (#846)" do
    alias Custode.Operator.Actions

    test "shared actions refuse every explicit nonhuman actor before mutation" do
      workflow = register(fixed_workflow(uid("authority")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))

      for actor <- [
            nil,
            %{},
            %{kind: :routine, id: "caretaker"},
            %{kind: :routine, id: "worker"},
            %{kind: :sub_agent, id: "helper"}
          ] do
        assert {:error, _} = Actions.approve_launch(proposal.id, actor: actor)
        assert {:error, _} = Actions.reject_launch(proposal.id, "no", actor: actor)
      end

      assert Run.list() == []
      assert decisions(proposal.id) == []
      assert Enum.any?(Launch.pending(), &(&1["proposal"] == proposal.id))
    end

    for pair <- [[:approve, :approve], [:reject, :reject], [:approve, :reject]] do
      @pair pair
      test "concurrent #{Enum.join(pair, "/")} consumes exactly one proposal" do
        workflow = register(fixed_workflow(uid("concurrent")))
        {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
        caller = self()

        tasks =
          for decision <- @pair do
            Task.async(fn ->
              send(caller, {:ready, self()})

              receive do
                :decide ->
                  case decision do
                    :approve -> Launch.approve(proposal.id)
                    :reject -> Launch.reject(proposal.id, "first reason")
                  end
              end
            end)
          end

        for _ <- tasks, do: assert_receive({:ready, _pid}, 1_000)
        for task <- tasks, do: send(task.pid, :decide)
        outcomes = Enum.map(tasks, &Task.await(&1, 10_000))
        assert [decision] = decisions(proposal.id)
        assert Launch.pending() == []

        case decision["event"] do
          "workflow_launch_approved" ->
            assert [run] = Run.list()
            assert run.context["launch_admission_pending"] == false
            assert decision["run"] == run.run_id
            assert length(jobs(run.run_id)) == 2

            assert Enum.count(outcomes, &match?({:ok, _}, &1)) ==
                     Enum.count(@pair, &(&1 == :approve))

            assert {:ok, replay} = Launch.approve(proposal.id)
            assert replay.run_id == run.run_id
            assert {:error, :decision_conflict} = Launch.reject(proposal.id)

          "workflow_launch_rejected" ->
            assert Run.list() == []
            assert Enum.count(outcomes, &(&1 == :ok)) == Enum.count(@pair, &(&1 == :reject))
            assert :ok = Launch.reject(proposal.id, "replacement reason")
            assert [retained] = decisions(proposal.id)
            assert retained["reason"] == "first reason"
            assert {:error, :decision_conflict} = Launch.approve(proposal.id)
        end

        assert length(decisions(proposal.id)) == 1
      end
    end

    for {state, selection} <- [
          {"cancelled", :one},
          {"cancelled", :all},
          {"discarded", :one},
          {"discarded", :all}
        ] do
      @terminal_state state
      @selection selection
      test "approval replay does not replace #{@selection} #{@terminal_state} nodes" do
        workflow = register(fixed_workflow(uid("terminal-replay")))
        {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
        {:ok, run} = Launch.approve(proposal.id)
        initial = jobs(run.run_id)
        assert length(initial) == 2
        selected = if @selection == :one, do: Enum.take(initial, 1), else: initial
        ids = Enum.map(selected, & &1.id)
        Repo.update_all(from(j in Oban.Job, where: j.id in ^ids), set: [state: @terminal_state])
        retained_jobs = jobs(run.run_id)
        assert Enum.count(retained_jobs, &(&1.state == @terminal_state)) == length(ids)
        retained_run = Run.get(run.run_id)
        assert retained_run.status == "running"
        assert retained_run.context["launch_admission_pending"] == false

        assert {:ok, ^retained_run} = Launch.approve(proposal.id)
        assert jobs(run.run_id) == retained_jobs
        assert Enum.map(jobs(run.run_id), & &1.id) == Enum.map(initial, & &1.id)
        assert length(decisions(proposal.id)) == 1
      end
    end

    test "context prompts and job hashes use the consumed admission state" do
      workflow =
        Workflow.new!(uid("context-hash"), [
          %Stage{
            name: :mine,
            nodes: [
              %Node{name: :inspect, prompt: "context <%= Jason.encode!(@context) %>", schema: %{}}
            ]
          }
        ])
        |> register()

      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
      assert {:ok, run} = Launch.approve(proposal.id)
      assert [job] = jobs(run.run_id)
      assert run.context["launch_admission_pending"] == false
      assert [planned] = Runner.plan(Run.get(run.run_id), workflow)
      assert job.args["prompt"] == planned.prompt
      assert job.meta["args_hash"] == planned.args_hash
      assert ResultContract.check(run, job) == :ok

      assert {:ok, _} = Runner.advance(run.run_id)
      assert {:ok, _} = Launch.approve(proposal.id)
      assert [same_job] = jobs(run.run_id)
      assert same_job.id == job.id
      assert same_job.meta["args_hash"] == planned.args_hash
    end

    test "pruned jobs and launch events do not restore approval dispatch authority" do
      workflow = register(fixed_workflow(uid("pruned-replay")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
      {:ok, run} = Launch.approve(proposal.id)
      assert length(jobs(run.run_id)) == 2

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id
        )
      )

      Repo.delete_all(
        from(f in Feed.Entry,
          where:
            f.event == "workflow_launched" and
              fragment("json_extract(?, '$.run')", f.entry) == ^run.run_id
        )
      )

      assert Run.get(run.run_id).context["launch_admission_pending"] == false
      assert {:ok, ^run} = Launch.approve(proposal.id)
      assert jobs(run.run_id) == []
      assert length(decisions(proposal.id)) == 1
    end

    test "legacy admission with no marker or jobs returns retained state without dispatch" do
      workflow = register(fixed_workflow(uid("legacy-replay")))

      for context <- [
            %{},
            %{"launch_admission_pending" => false},
            %{"launch_admission_pending" => "true"},
            %{"launch_admission_pending" => 1}
          ] do
        {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
        run = Run.start(uid("legacy-run"), workflow.name, proposal.repo, :mine, context)
        Feed.record(%{event: "workflow_launch_approved", proposal: proposal.id, run: run.run_id})
        refute run.context["launch_admission_pending"] == true
        assert jobs(run.run_id) == []
        assert {:ok, ^run} = Launch.approve(proposal.id)
        assert jobs(run.run_id) == []
        assert Run.get(run.run_id) == run
      end
    end

    test "first postcommit dispatch racing an approval retry consumes one initial jobset" do
      workflow = register(fixed_workflow(uid("first-dispatch-race")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))

      {:ok, run} =
        Repo.transaction(
          fn ->
            {:ok, run, _event} = Runner.prepare_launch(workflow.name, proposal.repo, [])

            {:ok, _decision} =
              Feed.record_in_transaction(%{
                event: "workflow_launch_approved",
                proposal: proposal.id,
                run: run.run_id
              })

            run
          end,
          mode: :immediate
        )

      assert run.context["launch_admission_pending"] == true
      assert jobs(run.run_id) == []
      caller = self()

      tasks =
        for operation <- [
              fn -> Runner.advance_admitted(run.run_id) end,
              fn -> Launch.approve(proposal.id) end
            ] do
          Task.async(fn ->
            send(caller, {:ready, self()})

            receive do
              :dispatch -> operation.()
            end
          end)
        end

      for _ <- tasks, do: assert_receive({:ready, _pid}, 1_000)
      for task <- tasks, do: send(task.pid, :dispatch)
      outcomes = Enum.map(tasks, &Task.await(&1, 10_000))

      for {:ok, admitted} <- outcomes do
        assert admitted.run_id == run.run_id
        assert admitted.context["launch_admission_pending"] == false
      end

      assert Enum.all?(outcomes, &match?({:ok, _}, &1))
      assert length(jobs(run.run_id)) == 2
      assert Run.get(run.run_id).context["launch_admission_pending"] == false
      job_ids = Enum.map(jobs(run.run_id), & &1.id)
      assert {:ok, _same_run} = Launch.approve(proposal.id)
      assert Enum.map(jobs(run.run_id), & &1.id) == job_ids
    end

    test "supplied context cannot suppress initial dispatch or reauthorize a replay" do
      workflow = register(fixed_workflow(uid("context-spoof")))

      for supplied <- [
            %{launch_admission_pending: false},
            %{"launch_admission_pending" => false},
            %{"launch_admission_pending" => true},
            %{"launch_admission_pending" => "true"}
          ] do
        {:ok, proposal} = Launch.propose(workflow.name, uid("repo"), context: supplied)
        {:ok, run} = Launch.approve(proposal.id)
        assert run.context["launch_admission_pending"] == false
        assert length(jobs(run.run_id)) == 2
        ids = Enum.map(jobs(run.run_id), & &1.id)
        Repo.update_all(from(j in Oban.Job, where: j.id in ^ids), set: [state: "cancelled"])

        Repo.query!(
          "UPDATE feed_entries SET entry = json_set(entry, '$.launch_opts.context.launch_admission_pending', json('true')) WHERE event = 'workflow_launch_proposed' AND json_extract(entry, '$.proposal') = ?",
          [proposal.id]
        )

        retained = jobs(run.run_id)
        assert {:ok, replay} = Launch.approve(proposal.id)
        assert replay.context["launch_admission_pending"] == false
        assert jobs(run.run_id) == retained
      end

      assert {:ok, direct} =
               Runner.launch(workflow.name, uid("repo"),
                 context: %{launch_admission_pending: false}
               )

      assert direct.context["launch_admission_pending"] == false
      assert length(jobs(direct.run_id)) == 2
    end

    test "initial budget pause consumes dispatch evidence without authorizing replay to resume" do
      workflow = register(fixed_workflow(uid("initial-pause")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"), budget_usd: 0.0)
      assert {:ok, run} = Launch.approve(proposal.id)
      assert run.status == "budget_paused"
      assert run.context["launch_admission_pending"] == false
      assert jobs(run.run_id) == []
      assert {:ok, ^run} = Launch.approve(proposal.id)
      assert jobs(run.run_id) == []
    end

    test "initial definition failure commits consumption with the failed state" do
      workflow = register(fixed_workflow(uid("initial-failure")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))

      {:ok, run} =
        Repo.transaction(
          fn ->
            {:ok, run, _event} = Runner.prepare_launch(workflow.name, proposal.repo, [])

            {:ok, _decision} =
              Feed.record_in_transaction(%{
                event: "workflow_launch_approved",
                proposal: proposal.id,
                run: run.run_id
              })

            run
          end,
          mode: :immediate
        )

      assert run.context["launch_admission_pending"] == true
      register(%{workflow | stages: Enum.reverse(workflow.stages)})
      assert {:ok, failed} = Launch.approve(proposal.id)
      assert failed.status == "failed"
      assert failed.context["launch_admission_pending"] == false
      assert jobs(run.run_id) == []
      register(workflow)
      assert {:ok, ^failed} = Launch.approve(proposal.id)
      assert jobs(run.run_id) == []
    end

    test "a failure after run insertion rolls back both events and publishes nothing" do
      workflow = register(fixed_workflow(uid("rollback")))
      mirror = Path.join(tmp_workspace!(), "feed.jsonl")
      put_env!(:feed_path, mirror)
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
      before_mirror = File.read!(mirror)
      :ok = Custode.PubSubBridge.subscribe()
      trigger = uid("launch_abort") |> String.replace("-", "_")

      Repo.query!("""
      CREATE TRIGGER #{trigger} BEFORE INSERT ON feed_entries
      WHEN NEW.event = 'workflow_launch_approved'
        AND json_extract(NEW.entry, '$.proposal') = '#{proposal.id}'
      BEGIN SELECT RAISE(ABORT, 'fixture approval write failure'); END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS #{trigger}") end)
      assert {:error, _} = Launch.approve(proposal.id)
      assert Run.list() == []
      assert decisions(proposal.id) == []

      assert Repo.aggregate(
               from(j in Oban.Job, where: j.worker == "Custode.Workflow.NodeJob"),
               :count
             ) == 0

      assert Feed.recent_by_event("workflow_launched") == []
      assert File.read!(mirror) == before_mirror
      refute_receive {:feed_entry, %{"event" => "workflow_launched"}}
      proposal_id = proposal.id
      refute_receive {:feed_entry, %{"proposal" => ^proposal_id}}
      assert Enum.any?(Launch.pending(), &(&1["proposal"] == proposal.id))
      Repo.query!("DROP TRIGGER #{trigger}")
      assert {:ok, _run} = Launch.approve(proposal.id)
    end

    test "committed admission without advance is recovered by retry and boot resume" do
      workflow = register(fixed_workflow(uid("recovery")))

      for recovery <- [:retry, :boot] do
        {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))

        {:ok, run} =
          Repo.transaction(
            fn ->
              {:ok, run, _unpublished} =
                Runner.prepare_launch(workflow.name, proposal.repo, budget_usd: 3.5)

              {:ok, _decision} =
                Feed.record_in_transaction(%{
                  event: "workflow_launch_approved",
                  proposal: proposal.id,
                  run: run.run_id
                })

              run
            end,
            mode: :immediate
          )

        assert jobs(run.run_id) == []
        assert run.context["launch_admission_pending"] == true

        case recovery do
          :retry ->
            assert {:ok, replay} = Launch.approve(proposal.id)
            assert replay.run_id == run.run_id

          :boot ->
            outcomes = Runner.resume_all()

            assert Enum.any?(outcomes, fn {id, outcome} ->
                     id == run.run_id and match?({:ok, _}, outcome)
                   end)
        end

        assert Run.get(run.run_id).context["launch_admission_pending"] == false
        assert length(jobs(run.run_id)) == 2
        assert {:ok, replay} = Launch.approve(proposal.id)
        assert replay.run_id == run.run_id
        assert replay.context["launch_admission_pending"] == false
        assert length(jobs(run.run_id)) == 2
        assert length(decisions(proposal.id)) == 1
      end

      assert length(Run.list()) == 2
    end

    test "postcommit advance failure retains admission and retry recovers the same run" do
      workflow = register(fixed_workflow(uid("advance_failure")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))
      trigger = uid("enqueue_abort") |> String.replace("-", "_")

      Repo.query!("""
      CREATE TRIGGER #{trigger} BEFORE INSERT ON oban_jobs
      WHEN json_extract(NEW.meta, '$.workflow') = '#{workflow.name}'
      BEGIN SELECT RAISE(ABORT, 'fixture enqueue failure'); END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS #{trigger}") end)
      assert {:ok, admitted} = Launch.approve(proposal.id)
      assert admitted == Run.get(admitted.run_id)
      assert admitted.context["launch_admission_pending"] == true
      assert jobs(admitted.run_id) == []
      assert [decision] = decisions(proposal.id)
      assert decision["run"] == admitted.run_id
      assert Launch.pending() == []
      assert {:error, :decision_conflict} = Launch.reject(proposal.id)
      Repo.query!("DROP TRIGGER #{trigger}")
      assert {:ok, recovered} = Launch.approve(proposal.id)
      assert recovered.run_id == admitted.run_id
      assert recovered.context["launch_admission_pending"] == false
      assert length(Run.list()) == 1
      assert length(jobs(admitted.run_id)) == 2
    end

    test "more than fifty later decisions cannot resurrect or replace resolved proposals" do
      workflow = register(fixed_workflow(uid("history")))
      {:ok, rejected} = Launch.propose(workflow.name, uid("repo"))
      {:ok, approved} = Launch.propose(workflow.name, uid("repo"))
      assert :ok = Launch.reject(rejected.id)
      assert {:ok, run} = Launch.approve(approved.id)

      for _ <- 1..51, event <- ~w(workflow_launch_approved workflow_launch_rejected) do
        Feed.record(%{event: event, proposal: uid("later"), run: uid("later-run")})
      end

      assert Launch.pending() == []
      assert :ok = Launch.reject(rejected.id)
      assert {:error, :decision_conflict} = Launch.approve(rejected.id)
      assert {:ok, replay} = Launch.approve(approved.id)
      assert replay.run_id == run.run_id
      assert length(Run.list()) == 1
    end

    test "a pending proposal outside the display window remains decidable by exact ID" do
      workflow = register(fixed_workflow(uid("hidden")))
      {:ok, hidden} = Launch.propose(workflow.name, uid("repo"))
      for _ <- 1..51, do: Launch.propose(workflow.name, uid("later-repo"))
      refute Enum.any?(Launch.pending(), &(&1["proposal"] == hidden.id))
      assert {:ok, run} = Launch.approve(hidden.id)
      assert {:ok, replay} = Launch.approve(hidden.id)
      assert replay.run_id == run.run_id
      assert length(Run.list()) == 1
      assert length(decisions(hidden.id)) == 1
    end

    test "missed postcommit publication does not undo approval or rejection" do
      workflow = register(fixed_workflow(uid("publication")))
      {:ok, approval} = Launch.propose(workflow.name, uid("repo"))
      {:ok, rejection} = Launch.propose(workflow.name, uid("repo"))
      # A directory is not an appendable mirror. Durable history still commits.
      put_env!(:feed_path, tmp_workspace!())
      assert {:ok, run} = Launch.approve(approval.id)
      assert :ok = Launch.reject(rejection.id)
      assert length(decisions(approval.id)) == 1
      assert length(decisions(rejection.id)) == 1
      assert {:ok, replay} = Launch.approve(approval.id)
      assert replay.run_id == run.run_id
      assert Launch.pending() == []
    end

    test "unknown, expired and invalid-definition proposals stay unconsumed" do
      workflow = register(fixed_workflow(uid("stale")))
      assert {:error, :no_such_proposal} = Launch.approve(uid("unknown"))
      assert {:error, :no_such_proposal} = Launch.reject(uid("unknown"))
      {:ok, expired} = Launch.propose(workflow.name, uid("repo"))
      cutoff = DateTime.add(DateTime.utc_now(), -8 * 24 * 60 * 60)

      Repo.update_all(
        from(f in Feed.Entry,
          where: fragment("json_extract(?, '$.proposal')", f.entry) == ^expired.id
        ),
        set: [at: cutoff]
      )

      assert {:error, :expired_proposal} = Launch.approve(expired.id)
      assert {:error, :expired_proposal} = Launch.reject(expired.id)
      {:ok, invalid} = Launch.propose(workflow.name, uid("repo"))
      register(%{workflow | stages: []})
      assert {:error, _} = Launch.approve(invalid.id)
      assert decisions(invalid.id) == []
      Application.put_env(:custode, :extra_workflows, %{})
      assert {:error, :unknown_workflow} = Launch.approve(invalid.id)
      assert Run.list() == []
      assert Enum.any?(Launch.pending(), &(&1["proposal"] == invalid.id))
    end

    test "missing retained run and unsupported outer transactions refuse without a new run" do
      workflow = register(fixed_workflow(uid("missing")))
      {:ok, proposal} = Launch.propose(workflow.name, uid("repo"))

      assert {:ok, :ok} =
               Repo.transaction(fn ->
                 assert {:error, :outer_transaction_unsupported} = Launch.approve(proposal.id)
                 assert {:error, :outer_transaction_unsupported} = Launch.reject(proposal.id)

                 assert {:error, :outer_transaction_unsupported} =
                          Runner.launch(workflow.name, proposal.repo)

                 :ok
               end)

      assert_raise ArgumentError, fn ->
        Runner.prepare_launch(workflow.name, proposal.repo, [])
      end

      Feed.record(%{
        event: "workflow_launch_approved",
        proposal: proposal.id,
        run: uid("missing-run")
      })

      assert {:error, :retained_run_missing} = Launch.approve(proposal.id)
      assert Run.list() == []
      assert Launch.pending() == []
    end
  end

  defp decisions(proposal_id) do
    events = ~w(workflow_launch_approved workflow_launch_rejected)

    Repo.all(
      from(f in Feed.Entry,
        where:
          f.event in ^events and
            fragment("json_extract(?, '$.proposal')", f.entry) == ^proposal_id,
        select: f.entry
      )
    )
    |> Enum.map(&Jason.decode!/1)
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
      assert mine.name == "mine"
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

  describe "recorded failure display (#750)" do
    test "first, middle and final stopping stages are failed, with later stages not run" do
      cases = [
        {"code", ["spec"], [:failed, :not_run, :not_run]},
        {"merge", ["spec", "code"], [:done, :failed, :not_run]},
        {"check_1", ["spec", "code", "merge"], [:done, :done, :failed]}
      ]

      for {failed_node, finished_nodes, states} <- cases do
        workflow = register(fanning_workflow(uid("stopping-stage")))
        {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))
        for node <- finished_nodes, do: finish(run.run_id, node, %{"items" => ["finding"]})
        job = Enum.find(jobs(run.run_id), &(&1.meta["node_name"] == failed_node))
        Runner.node_failed(job.meta, {:cancel, :fixture_failure})
        failed = Run.get(run.run_id)
        saved = Results.for_run(run.run_id)
        job_count = length(jobs(run.run_id))

        checklist = Launch.checklist(failed)

        assert Enum.map(checklist, & &1.state) == states
        assert Enum.map(Enum.flat_map(checklist, & &1.nodes), & &1.node_name) == finished_nodes
        assert [stopping_stage] = Enum.filter(checklist, &(&1.state == :failed))
        assert to_string(stopping_stage.name) == failed.stage
        assert stopping_stage.error == failed.error
        assert Enum.all?(Enum.reject(checklist, &(&1.state == :failed)), &is_nil(&1.error))
        assert Results.for_run(run.run_id) == saved
        assert Run.get(run.run_id) == failed
        assert length(jobs(run.run_id)) == job_count
      end
    end

    test "unavailable catalog and nil or unknown cursor retain error and all saved results" do
      workflow = register(fanning_workflow(uid("unavailable-stage")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))
      finish(run.run_id, "spec")
      failed = Run.fail(run.run_id, "node merge failed; code and check are mentioned as prose")
      saved = Results.for_run(run.run_id)

      cases = [
        {%{failed | workflow: "removed-workflow", definition_snapshot: nil},
         :workflow_unavailable},
        {%{failed | stage: nil}, :stage_unavailable},
        {%{failed | stage: "merge_missing"}, :stage_unavailable}
      ]

      for {recorded, reason} <- cases do
        assert [entry] = Launch.checklist(recorded)
        assert entry.state == :unavailable
        assert entry.unavailable_reason == reason
        assert entry.name == recorded.stage
        assert entry.error == failed.error
        assert entry.nodes == saved
      end

      assert Run.get(run.run_id) == failed
      assert Results.for_run(run.run_id) == saved
    end

    test "a missing failure message still identifies the recorded stage" do
      workflow = register(fanning_workflow(uid("no-error")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))

      assert [failed, later, last] = Launch.checklist(%{run | status: "failed", error: nil})
      assert failed.state == :failed
      assert failed.error == nil
      assert later.state == :not_run
      assert last.state == :not_run
    end

    test "budget-paused cursor stays pending and its reason stays at run level" do
      workflow = register(fanning_workflow(uid("paused-display")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("run"))
      finish(run.run_id, "spec")
      finish(run.run_id, "code")
      paused = Run.budget_pause(run.run_id, "budget rail hit")

      assert [mine, merge, check] = Launch.checklist(paused)
      assert [mine.state, merge.state, check.state] == [:done, :pending, :pending]
      assert Enum.all?([mine, merge, check], &is_nil(&1.error))
      assert paused.error == "budget rail hit"
    end
  end

  describe "attention (#447)" do
    alias Custode.Attention.Fleet

    defp workflow_signals do
      Enum.filter(Fleet.signals(), &(&1.kind in [:workflow_launch, :workflow_rail]))
    end

    defp park!(run) do
      finish(run.run_id, "spec")
      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")
      assert Run.get(run.run_id).status == "budget_paused"
    end

    test "a standing proposal is a needs-you signal until it is decided" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", why: "the board is dry")

      assert [signal] = workflow_signals()
      assert signal.kind == :workflow_launch
      assert signal.group == :needs_you
      assert signal.subject == "#{workflow.name} on owner/repo"
      assert signal.item == {:proposal, proposal.id}
      assert signal.detail =~ "the board is dry"
      assert %DateTime{} = signal.raised_at

      assert :ok = Launch.reject(proposal.id, "not now")
      assert workflow_signals() == []
    end

    test "approving clears the proposal's signal and raises none for the healthy run" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo")
      {:ok, _run} = Launch.approve(proposal.id)

      assert workflow_signals() == []
    end

    test "a run parked on its rail is a needs-you signal, dated from the pause" do
      workflow = register(fanning_workflow(uid("railed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
      {:ok, run} = Launch.approve(proposal.id)
      park!(run)

      assert [signal] = workflow_signals()
      assert signal.kind == :workflow_rail
      assert signal.group == :needs_you
      assert signal.item == {:run, run.run_id}
      assert signal.detail =~ "run budget rail hit"
      assert signal.detail =~ "merge"
      assert %DateTime{} = signal.raised_at
    end

    test "raise_and_resume/1 doubles the rail, lets the run go on and clears the signal" do
      workflow = register(fanning_workflow(uid("railed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
      {:ok, run} = Launch.approve(proposal.id)
      park!(run)

      assert {:ok, resumed} = Launch.raise_and_resume(run.run_id)
      assert resumed.status == "running"
      assert resumed.budget_usd == 2.0
      assert Enum.any?(jobs(run.run_id), &(&1.meta["node_name"] == "merge"))
      assert workflow_signals() == []
    end

    test "raise_and_resume/1 refuses a run that is not parked, and one that does not exist" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, run} = Runner.launch(workflow.name, "owner/repo", run_id: uid("live"))

      assert {:error, :not_paused} = Launch.raise_and_resume(run.run_id)
      assert {:error, :no_such_run} = Launch.raise_and_resume(uid("ghost"))
    end
  end

  describe "the operator's ops (#447)" do
    alias Custode.Operator.Actions

    test "run/4 approves a launch from the signal's own args" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 3.5)

      assert Actions.handles?(:approve_launch)
      assert :ok = Actions.run(:approve_launch, %{proposal: proposal.id}, %{}, via: :liveview)
      assert [%{status: "running", budget_usd: 3.5}] = Run.list()
      assert Launch.pending() == []

      # A lost click response can be retried without admitting another run.
      assert :ok = Actions.run(:approve_launch, %{proposal: proposal.id}, %{}, via: :liveview)
      assert length(Run.list()) == 1
    end

    test "run/4 rejects a launch, with the reason given or the surface it came from" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, first} = Launch.propose(workflow.name, "owner/one")
      {:ok, second} = Launch.propose(workflow.name, "owner/two")

      assert Actions.handles?(:reject_launch)

      assert :ok =
               Actions.run(:reject_launch, %{proposal: first.id}, %{"reason" => "not this week"})

      assert :ok = Actions.run(:reject_launch, %{proposal: second.id}, %{}, via: :cli)

      summaries =
        "workflow_launch_rejected" |> Feed.recent_by_event() |> Enum.map(& &1["summary"])

      assert Enum.any?(summaries, &(&1 =~ "owner/one: not this week"))
      assert Enum.any?(summaries, &(&1 =~ "owner/two: rejected via cli"))
      assert Run.list() == []
    end

    test "run/4 raises the rail of a parked run and lets it go on" do
      workflow = register(fanning_workflow(uid("railed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
      {:ok, run} = Launch.approve(proposal.id)
      park!(run)

      assert Actions.handles?(:resume_run)
      assert :ok = Actions.run(:resume_run, %{run: run.run_id}, %{}, via: :liveview)
      assert %{status: "running", budget_usd: 2.0} = Run.get(run.run_id)
      assert {:error, :not_paused} = Actions.run(:resume_run, %{run: run.run_id})
    end
  end

  describe "the desktop notification (#447)" do
    setup do
      test_pid = self()
      Application.put_env(:custode, :desktop_notifications, true)
      Application.put_env(:custode, :desktop_sink, &send(test_pid, {:desktop, &1}))

      on_exit(fn ->
        Application.put_env(:custode, :desktop_notifications, false)
        Application.delete_env(:custode, :desktop_sink)
      end)
    end

    test "a launch proposal raises one, with the estimate as its body" do
      workflow = register(fixed_workflow(uid("fixed")))
      {:ok, _proposal} = Launch.propose(workflow.name, "owner/repo")

      assert_receive {:desktop, message}, 500
      assert message.title == "custode: workflow_launch_proposed"
      assert message.body =~ "run #{workflow.name} on owner/repo"
    end

    test "a run parking on its rail raises one; approving and rejecting do not" do
      workflow = register(fanning_workflow(uid("railed")))
      {:ok, proposal} = Launch.propose(workflow.name, "owner/repo", budget_usd: 1.0)
      assert_receive {:desktop, %{title: "custode: workflow_launch_proposed"}}, 500

      {:ok, run} = Launch.approve(proposal.id)
      finish(run.run_id, "spec")
      refute_receive {:desktop, _message}, 100

      SpendLedger.record(Run.spend_agent_id(run.run_id), 1.20)
      finish(run.run_id, "code")

      assert_receive {:desktop, message}, 500
      assert message.title == "custode: workflow_budget_paused"
      assert message.body =~ "run budget rail hit"
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
