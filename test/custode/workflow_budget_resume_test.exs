defmodule Custode.WorkflowBudgetResumeTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers, only: [put_env!: 2, tmp_workspace!: 0, uid: 1]
  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo, SpendLedger, Workflow}
  alias Custode.Operator.Actions
  alias Custode.Workflow.{BudgetResume, Node, Results, Run, Runner, Stage}

  setup do
    name = uid("budget-resume-workflow")
    repo = uid("budget-resume-repo")
    workspace = tmp_workspace!()

    workflow =
      Workflow.new!(name, [
        %Stage{
          name: :fixture,
          nodes: [
            %Node{
              name: :fixture,
              prompt: "fixture <%= Jason.encode!(@context) %>",
              schema: %{}
            }
          ]
        }
      ])

    put_env!(:extra_workflows, %{name => workflow})

    on_exit(fn ->
      run_ids = Repo.all(from(r in Run.Row, where: r.repo == ^repo, select: r.run_id))
      spend_ids = Enum.map(run_ids, &Run.spend_agent_id/1)

      Repo.delete_all(
        from(j in Oban.Job,
          where: fragment("json_extract(?, '$.workflow_run')", j.meta) in ^run_ids
        )
      )

      Repo.delete_all(from(r in Results.Result, where: r.workflow_run in ^run_ids))
      Repo.delete_all(from(r in BudgetResume.Row, where: r.run_id in ^run_ids))
      Repo.delete_all(from(r in Run.Row, where: r.repo == ^repo))
      Repo.delete_all(from(s in SpendLedger.Entry, where: s.agent_id in ^spend_ids))

      Repo.delete_all(
        from(f in Feed.Entry, where: fragment("json_extract(?, '$.run')", f.entry) in ^run_ids)
      )
    end)

    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false
    %{name: name, repo: repo, workspace: workspace, workflow: workflow}
  end

  test "one pause retains its reference until a genuine new pause", ctx do
    paused = paused_run(ctx)
    assert is_binary(paused.budget_pause_id)
    assert %DateTime{} = paused.budget_paused_at
    repeated = Run.budget_pause(paused.run_id, "same pause", ["fixture"])
    assert repeated.budget_pause_id == paused.budget_pause_id
    assert repeated.budget_paused_at == paused.budget_paused_at
    assert repeated.budget_resume_pending == nil

    unpaused = Run.unpause(paused.run_id)
    assert_clear_admission(unpaused)
    next = Run.budget_pause(paused.run_id, "new pause", ["fixture"])
    assert next.budget_pause_id != paused.budget_pause_id
    assert %DateTime{} = next.budget_paused_at
  end

  test "a legacy pause retains its unknown timestamp on repeated observation", ctx do
    paused = paused_run(ctx)

    Repo.update_all(from(r in Run.Row, where: r.run_id == ^paused.run_id),
      set: [budget_paused_at: nil]
    )

    repeated = Run.budget_pause(paused.run_id, "same legacy pause", ["fixture"])
    assert repeated.budget_pause_id == paused.budget_pause_id
    assert repeated.budget_paused_at == nil
  end

  test "concurrent decisions retain one rail increase, receipt, event and job", ctx do
    paused = paused_run(ctx)
    actor = %{kind: :operator, id: uid("human")}

    results =
      concurrently(for _ <- 1..4, do: fn -> resume(paused, actor: actor, via: :mcp) end)

    assert [{:ok, receipt} | _] = results
    assert Enum.all?(results, &(&1 == {:ok, receipt}))
    assert receipt == expected_receipt(paused, 2.0)
    assert [%{actor_id: actor_id, via: "mcp", admitted_at: %DateTime{}}] = admissions(paused)
    assert actor_id == actor.id
    assert length(events(paused)) == 1
    assert [job] = jobs(paused)
    assert job.attempt == 0
    assert job.state in ["available", "scheduled"]
    retained = Run.get(paused.run_id)
    assert retained.status == "running"
    assert retained.budget_usd == 2.0
    assert retained.context == paused.context
    assert_clear_admission(retained)

    assert {:ok, ^receipt} = resume(paused, actor: %{kind: :operator, id: uid("other-human")})
    assert [%{actor_id: ^actor_id, via: "mcp"}] = admissions(paused)
    assert length(events(paused)) == 1
  end

  test "an immediate second pause cannot be consumed by a lost-response retry", ctx do
    paused = paused_run(ctx, spend: 5.0)
    assert {:ok, first} = resume(paused)
    assert first == expected_receipt(paused, 2.0)
    second_pause = Run.get(paused.run_id)
    assert second_pause.status == "budget_paused"
    assert second_pause.budget_usd == 2.0
    assert second_pause.budget_pause_id != paused.budget_pause_id
    assert second_pause.budget_resume_pending == nil
    assert jobs(paused) == []

    assert {:ok, ^first} = resume(paused)
    assert Run.get(paused.run_id) == second_pause
    assert length(admissions(paused)) == 1
    assert length(events(paused)) == 1

    assert {:ok, second} = resume(second_pause)
    assert second == expected_receipt(second_pause, 4.0)
    third_pause = Run.get(paused.run_id)
    assert third_pause.status == "budget_paused"
    assert third_pause.budget_pause_id != second_pause.budget_pause_id
    assert third_pause.budget_usd == 4.0
    assert {:ok, ^first} = resume(paused)
    assert {:ok, ^second} = resume(second_pause)
    assert Run.get(paused.run_id) == third_pause

    assert {:ok, third} = resume(third_pause)
    assert third == expected_receipt(third_pause, 8.0)
    assert Run.get(paused.run_id).status == "running"
    assert length(jobs(paused)) == 1
    assert length(admissions(paused)) == 3
    assert length(events(paused)) == 3
  end

  test "an explicitly paused unbounded run remains unbounded", ctx do
    paused = paused_run(ctx, budget: nil)
    assert {:ok, receipt} = resume(paused)
    assert receipt == expected_receipt(paused, nil)
    assert Run.get(paused.run_id).budget_usd == nil
    assert length(jobs(paused)) == 1
  end

  test "shared and internal operations refuse missing or nonhuman identity without effects",
       ctx do
    paused = paused_run(ctx)
    before = snapshot(paused)

    for actor <- [
          nil,
          %{},
          %{kind: :routine, id: "caretaker"},
          %{kind: :sub_agent, id: "helper"},
          %{kind: :operator},
          %{kind: :operator, id: ""}
        ] do
      assert {:error, _} = resume(paused, actor: actor)

      assert {:error, :human_identity_required} =
               BudgetResume.resume(paused.run_id, paused.budget_pause_id, actor, :mcp)

      assert snapshot(paused) == before
    end
  end

  test "missing, stale, unknown and nonpaused references cannot mutate work", ctx do
    paused = paused_run(ctx)
    before = snapshot(paused)

    for invalid <- [nil, "", String.duplicate("x", 161)] do
      assert {:error, :pause_required} = Actions.resume_run(paused.run_id, invalid)
    end

    assert {:error, :stale_pause} = Actions.resume_run(paused.run_id, uid("old-pause"))
    assert {:error, :no_such_run} = Actions.resume_run(uid("missing-run"), paused.budget_pause_id)
    assert snapshot(paused) == before

    running = Run.unpause(paused.run_id)
    assert {:error, :not_paused} = resume(paused)
    assert Run.get(paused.run_id) == running
    assert admissions(paused) == []
    assert jobs(paused) == []
  end

  for terminal <- [:complete, :failed] do
    @terminal terminal

    test "#{terminal} clears pause authority and still returns a previously admitted receipt",
         ctx do
      paused = paused_run(ctx)
      assert {:ok, receipt} = resume(paused)
      terminal = finish(paused, @terminal)
      assert_clear_admission(terminal)
      retained_jobs = jobs(paused)
      assert {:ok, ^receipt} = resume(paused)
      assert Run.get(paused.run_id) == terminal
      assert jobs(paused) == retained_jobs
      assert length(admissions(paused)) == 1
      assert length(events(paused)) == 1

      never_admitted = paused_run(ctx)
      finished = finish(never_admitted, @terminal)
      assert_clear_admission(finished)
      assert {:error, :not_paused} = resume(never_admitted)
      assert Run.get(never_admitted.run_id) == finished
      assert admissions(never_admitted) == []
      assert jobs(never_admitted) == []
    end
  end

  for job_state <- [:cancelled, :discarded, :pruned] do
    @job_state job_state

    test "retry never recreates #{@job_state} admitted work", ctx do
      paused = paused_run(ctx)
      assert {:ok, receipt} = resume(paused)
      assert [job] = jobs(paused)

      case @job_state do
        :pruned ->
          Repo.delete!(job)

        state ->
          Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
            set: [state: to_string(state)]
          )
      end

      # The durable decision, not retained jobs or the optional feed, is authority.
      Repo.delete_all(
        from(f in Feed.Entry,
          where: f.event == "workflow_resumed",
          where: fragment("json_extract(?, '$.run')", f.entry) == ^paused.run_id
        )
      )

      before = snapshot(paused)
      assert {:ok, ^receipt} = resume(paused)
      assert snapshot(paused) == before
      assert Run.get(paused.run_id).budget_resume_pending == nil
    end
  end

  test "budget admission never changes rendered context or planned argument hashes", ctx do
    paused = paused_run(ctx)
    assert [before] = Runner.plan(paused, ctx.workflow)
    assert {:ok, _receipt} = resume(paused)
    resumed = Run.get(paused.run_id)
    assert resumed.context == paused.context
    assert [after_resume] = Runner.plan(resumed, ctx.workflow)
    assert after_resume.prompt == before.prompt
    assert after_resume.args_hash == before.args_hash
    assert [job] = jobs(paused)
    assert job.args["prompt"] == before.prompt
    assert job.meta["args_hash"] == before.args_hash

    assert {:ok, _} = Runner.advance(paused.run_id)
    assert {:ok, _} = resume(paused)
    assert [same_job] = jobs(paused)
    assert same_job.id == job.id
    assert same_job.meta["args_hash"] == before.args_hash
  end

  test "shared resolving actions require the displayed pause and preserve human authority", ctx do
    paused = paused_run(ctx)
    args = %{run: paused.run_id, pause: paused.budget_pause_id}
    assert {:error, :pause_required} = Actions.run(:resume_run, %{run: paused.run_id})

    assert {:error, _} =
             Actions.run(:resume_run, args, %{}, actor: %{kind: :routine, id: "caretaker"})

    assert admissions(paused) == []
    assert :ok = Actions.run(:resume_run, args, %{}, via: :liveview)
    assert :ok = Actions.run(:resume_run, args, %{}, via: :liveview)
    assert length(admissions(paused)) == 1
    assert length(jobs(paused)) == 1
  end

  test "outer transactions refuse before admission or publication", ctx do
    paused = paused_run(ctx)
    before = snapshot(paused)

    assert {:ok, :ok} =
             Repo.transaction(fn ->
               assert {:error, :outer_transaction_unsupported} = resume(paused)
               :ok
             end)

    assert snapshot(paused) == before
  end

  test "a failed decision event rolls back the receipt, rail and marker without publication",
       ctx do
    mirror = Path.join(ctx.workspace, "feed.jsonl")
    File.write!(mirror, "")
    put_env!(:feed_path, mirror)
    paused = paused_run(ctx)
    before = snapshot(paused)
    before_mirror = File.read!(mirror)
    :ok = Custode.PubSubBridge.subscribe()

    trigger =
      abort_trigger!(
        "feed_entries",
        "NEW.event = 'workflow_resumed' AND json_extract(NEW.entry, '$.run') = '#{paused.run_id}'"
      )

    assert {:error, :admission_failed} = resume(paused)
    assert snapshot(paused) == before
    assert File.read!(mirror) == before_mirror
    run_id = paused.run_id
    refute_receive {:feed_entry, %{"event" => "workflow_resumed", "run" => ^run_id}}
    drop_trigger!(trigger)
    assert {:ok, _receipt} = resume(paused)
    assert length(admissions(paused)) == 1
    assert length(jobs(paused)) == 1
  end

  for recovery <- [:retry, :runner_resume] do
    @recovery recovery

    test "#{recovery} recovers only a committed admission whose dispatch transaction failed",
         ctx do
      paused = paused_run(ctx)

      trigger =
        abort_trigger!(
          "oban_jobs",
          "json_extract(NEW.meta, '$.workflow_run') = '#{paused.run_id}'"
        )

      assert {:ok, receipt} = resume(paused)
      admitted = Run.get(paused.run_id)
      assert admitted.status == "running"
      assert admitted.budget_usd == 2.0
      assert admitted.budget_resume_pending == paused.budget_pause_id
      assert admitted.budget_pause_id == nil
      assert jobs(paused) == []
      assert length(admissions(paused)) == 1
      assert length(events(paused)) == 1
      drop_trigger!(trigger)

      case @recovery do
        :retry -> assert {:ok, ^receipt} = resume(paused)
        :runner_resume -> assert {:ok, _resumed} = Runner.resume(paused.run_id)
      end

      assert [job] = jobs(paused)
      assert_clear_admission(Run.get(paused.run_id))
      Repo.delete!(job)
      assert {:ok, ^receipt} = resume(paused)
      assert jobs(paused) == []
      assert length(admissions(paused)) == 1
      assert length(events(paused)) == 1
    end
  end

  test "a concurrent terminal transition cannot be undone by admission or its retry", ctx do
    paused = paused_run(ctx)

    [decision, terminal] =
      concurrently([
        fn -> resume(paused) end,
        fn ->
          Repo.transaction(fn -> Run.fail(paused.run_id, "fixture failure") end, mode: :immediate)
        end
      ])

    assert {:ok, %{status: "failed"}} = terminal
    failed = Run.get(paused.run_id)
    assert failed.status == "failed"
    assert_clear_admission(failed)
    retained_jobs = jobs(paused)
    assert length(retained_jobs) <= 1

    case decision do
      {:ok, receipt} ->
        assert {:ok, ^receipt} = resume(paused)
        assert failed.budget_usd == 2.0
        assert length(admissions(paused)) == 1

      {:error, :not_paused} ->
        assert {:error, :not_paused} = resume(paused)
        assert failed.budget_usd == 1.0
        assert admissions(paused) == []
    end

    assert Run.get(paused.run_id) == failed
    assert jobs(paused) == retained_jobs
  end

  test "a newer pause or terminal transition clears an undispatched admission", ctx do
    for disposition <- [:new_pause, :complete, :failed] do
      paused = paused_run(ctx)

      trigger =
        abort_trigger!(
          "oban_jobs",
          "json_extract(NEW.meta, '$.workflow_run') = '#{paused.run_id}'"
        )

      assert {:ok, receipt} = resume(paused)
      assert Run.get(paused.run_id).budget_resume_pending == paused.budget_pause_id

      retained =
        case disposition do
          :new_pause -> Run.budget_pause(paused.run_id, "new fixture pause", ["fixture"])
          terminal -> finish(paused, terminal)
        end

      assert retained.budget_resume_pending == nil

      if disposition == :new_pause do
        assert retained.budget_pause_id != paused.budget_pause_id
        assert retained.status == "budget_paused"
      else
        assert_clear_admission(retained)
      end

      drop_trigger!(trigger)
      assert {:ok, ^receipt} = resume(paused)
      assert Run.get(paused.run_id) == retained
      assert jobs(paused) == []
      assert length(admissions(paused)) == 1
      assert length(events(paused)) == 1
    end
  end

  defp paused_run(ctx, opts \\ []) do
    run =
      Run.start(
        uid("budget-resume-run"),
        ctx.name,
        ctx.repo,
        :fixture,
        %{"working_dir" => ctx.workspace, "purpose" => "synthetic fixture"},
        Keyword.get(opts, :budget, 1.0)
      )

    if spend = opts[:spend], do: SpendLedger.record(Run.spend_agent_id(run.run_id), spend)
    Run.budget_pause(run.run_id, "fixture rail", ["fixture"])
  end

  defp resume(run, opts \\ []),
    do: Actions.resume_run(run.run_id, run.budget_pause_id, opts)

  defp expected_receipt(run, budget) do
    %{
      schema_version: "custode.workflow_budget_resume.v1",
      run_id: run.run_id,
      pause_id: run.budget_pause_id,
      decision: "resumed",
      previous_budget_usd: run.budget_usd,
      budget_usd: budget,
      status: "running"
    }
  end

  defp assert_clear_admission(run) do
    assert run.budget_pause_id == nil
    assert run.budget_paused_at == nil
    assert run.budget_resume_pending == nil
  end

  defp finish(run, :complete), do: Run.complete(run.run_id)
  defp finish(run, :failed), do: Run.fail(run.run_id, "fixture failure")

  defp jobs(run) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "Custode.Workflow.NodeJob",
        where: fragment("json_extract(?, '$.workflow_run')", j.meta) == ^run.run_id,
        order_by: [asc: j.id]
      )
    )
  end

  defp admissions(run),
    do:
      Repo.all(from(r in BudgetResume.Row, where: r.run_id == ^run.run_id, order_by: [asc: r.id]))

  defp events(run) do
    Repo.all(
      from(f in Feed.Entry,
        where: f.event == "workflow_resumed",
        where: fragment("json_extract(?, '$.run')", f.entry) == ^run.run_id,
        order_by: [asc: f.id]
      )
    )
  end

  defp snapshot(run), do: {Run.get(run.run_id), jobs(run), admissions(run), events(run)}

  defp concurrently(operations) do
    caller = self()

    tasks =
      Enum.map(operations, fn operation ->
        Task.async(fn ->
          send(caller, {:ready, self()})

          receive do
            :decide -> operation.()
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, _pid}, 1_000)
    for task <- tasks, do: send(task.pid, :decide)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp abort_trigger!(table, predicate) do
    trigger = uid("budget_resume_abort") |> String.replace("-", "_")

    Repo.query!("""
    CREATE TRIGGER #{trigger} BEFORE INSERT ON #{table}
    WHEN #{predicate}
    BEGIN SELECT RAISE(ABORT, 'fixture budget resume write failure'); END
    """)

    on_exit(fn -> drop_trigger!(trigger) end)
    trigger
  end

  defp drop_trigger!(trigger), do: Repo.query!("DROP TRIGGER IF EXISTS #{trigger}")
end
