defmodule Custode.InboxWakesTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    AgentHandoff,
    AgentHandoffIntent,
    Agents,
    InboxWake,
    InboxWakeJob,
    InboxWakes,
    Repo,
    SpendLedger
  }

  setup do
    Repo.delete_all(InboxWake)
    Repo.delete_all(from(j in Oban.Job, where: j.worker == "Custode.InboxWakeJob"))
    :ok
  end

  test "notes coalesce under one stable wake and debounce from the latest note" do
    routine = routine_fixture!(tmp_workspace!())
    first_at = ~U[2026-09-28 12:00:00Z]
    second_at = DateTime.add(first_at, 15, :second)

    assert {:ok, first} =
             InboxWakes.request(routine, now: first_at, debounce_seconds: 20)

    assert {:ok, second} =
             InboxWakes.request(routine, now: second_at, debounce_seconds: 20)

    assert second.wake_id == first.wake_id
    assert second.note_count == 2
    assert DateTime.compare(second.first_note_at, first_at) == :eq
    assert DateTime.compare(second.last_note_at, second_at) == :eq
    assert DateTime.compare(second.due_at, DateTime.add(second_at, 20, :second)) == :eq
    assert second.blocked_by == "debounce"

    assert [job] = wake_jobs(routine.id, first.wake_id)
    assert job.state == "scheduled"
  end

  test "claim rechecks a concurrently extended debounce deadline" do
    routine = routine_fixture!(tmp_workspace!())
    start_stub!(routine, :claude)
    first_at = DateTime.utc_now()

    assert {:ok, first} =
             InboxWakes.request(routine, now: first_at, debounce_seconds: 0)

    later_at = DateTime.add(first_at, 1, :second)

    assert :ok =
             InboxWakes.dispatch(routine.id, first.wake_id,
               now: first_at,
               before_claim: fn ->
                 assert {:ok, joined} =
                          InboxWakes.request(routine, now: later_at, debounce_seconds: 20)

                 assert joined.wake_id == first.wake_id
               end
             )

    refute_receive {:enqueued, :claude, _args, _meta}, 100

    assert %InboxWake{state: "pending", note_count: 2, due_at: due_at} =
             InboxWakes.get(routine.id)

    assert DateTime.compare(due_at, DateTime.add(later_at, 20, :second)) == :eq

    assert :ok = InboxWakes.dispatch(routine.id, first.wake_id, now: due_at)
    assert_receive {:enqueued, :claude, _args, meta}, 1_000
    assert meta["correlation_id"] =~ "inbox:#{first.wake_id}:"
  end

  test "a permanent delivery failure gets one retry and then holds without polling" do
    routine = routine_fixture!(tmp_workspace!())
    refusing_supervisor = start_supervised!({Task.Supervisor, max_children: 0})

    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    assert :ok =
             InboxWakes.dispatch(routine.id, wake.wake_id, task_supervisor: refusing_supervisor)

    assert %InboxWake{state: "pending", retry_count: 1} =
             retried =
             InboxWakes.get(routine.id)

    assert retried.blocked_by != "delivery_failed"
    assert [_retry_job] = wake_jobs(routine.id, wake.wake_id)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    after_retry = DateTime.add(retried.due_at, 1, :second)

    assert :ok =
             InboxWakes.dispatch(routine.id, wake.wake_id,
               now: after_retry,
               task_supervisor: refusing_supervisor
             )

    assert %InboxWake{
             state: "pending",
             blocked_by: "delivery_failed",
             retry_count: 1
           } = InboxWakes.get(routine.id)

    assert wake_jobs(routine.id, wake.wake_id) == []

    # A stale duplicate kickoff cannot restart the loop.
    assert :ok =
             InboxWakes.dispatch(routine.id, wake.wake_id,
               now: after_retry,
               task_supervisor: refusing_supervisor
             )

    assert wake_jobs(routine.id, wake.wake_id) == []

    # New activity is the explicit recovery event and grants a fresh bounded attempt.
    assert {:ok, reset} = InboxWakes.request(routine, debounce_seconds: 0)
    assert reset.wake_id == wake.wake_id
    assert reset.retry_count == 0
    assert reset.blocked_by == "debounce"
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: activity claimed during a turn becomes one follow-up wave" do
      provider = unquote(provider)
      put_env!(:presence_override, :away)
      routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
      start_stub!(routine, provider)

      assert :processing = Agents.submit_prompt(routine.id, "current turn")
      assert_receive {:enqueued, ^provider, _args, current_meta}

      first_at = DateTime.utc_now()

      assert {:ok, first} =
               InboxWakes.request(routine, debounce_seconds: 0, now: first_at)

      assert :ok = perform(first)

      eventually(fn ->
        assert %InboxWake{state: "pending", blocked_by: "running"} =
                 InboxWakes.get(routine.id)
      end)

      # Activity before the debounce cutoff joins the pending wave and moves
      # the deadline. Finishing the live turn does not bypass that deadline.
      joined_at = DateTime.add(first_at, 1, :second)

      assert {:ok, joined} =
               InboxWakes.request(routine, debounce_seconds: 0, now: joined_at)

      assert joined.wake_id == first.wake_id
      assert joined.note_count == 2
      assert DateTime.compare(joined.due_at, first.due_at) == :gt

      finish_turn(provider, current_meta)
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)
      refute_receive {:enqueued, ^provider, _args, _meta}, 100

      assert :ok = InboxWakes.dispatch(routine.id, first.wake_id, now: joined.due_at)

      # Duplicate kickoff execution cannot acquire the claimed row.
      assert :ok = InboxWakes.dispatch(routine.id, first.wake_id, now: joined.due_at)

      assert_receive {:enqueued, ^provider, %{"prompt" => prompt}, inbox_meta}, 1_000
      assert prompt =~ "sweep now"
      assert prompt =~ "operator: AWAY"
      assert inbox_meta["origin"] == "tick"
      assert inbox_meta["correlation_id"] =~ "inbox:#{first.wake_id}:"
      assert is_binary(inbox_meta["arc_id"])
      eventually(fn -> assert InboxWakes.get(routine.id) == nil end)

      finish_turn(provider, inbox_meta)
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)
      refute_receive {:enqueued, ^provider, _args, _meta}, 100

      # Once that exact turn reaches :running, later activity is a new wave.
      assert {:ok, next} = InboxWakes.request(routine, debounce_seconds: 0)
      refute next.wake_id == first.wake_id
      assert next.note_count == 1
    end
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: pause holds a wake and resume admits it" do
      provider = unquote(provider)
      routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
      start_stub!(routine, provider)

      Agents.emergency_pause(routine.id)
      assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)

      assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
      assert :ok = perform(wake)
      assert %InboxWake{state: "pending", blocked_by: "paused"} = InboxWakes.get(routine.id)
      refute_receive {:enqueued, ^provider, _args, _meta}, 50

      Agents.resume_agent(routine.id)
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)
      assert :ok = perform(wake)

      assert_receive {:enqueued, ^provider, _args, meta}, 1_000
      assert meta["correlation_id"] =~ "inbox:#{wake.wake_id}:"
      eventually(fn -> assert InboxWakes.get(routine.id) == nil end)
    end
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: a paused hold is restored across provider process loss" do
      provider = unquote(provider)
      routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
      pid = start_stub!(routine, provider)

      Agents.emergency_pause(routine.id)
      assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)

      assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
      assert :ok = perform(wake)
      assert %InboxWake{state: "pending", blocked_by: "paused"} = InboxWakes.get(routine.id)

      wake_jobs(routine.id, wake.wake_id)
      |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

      eventually(fn -> assert [_job] = wake_jobs(routine.id, wake.wake_id) end)
      assert :ok = perform(wake)
      assert {:ok, :paused} = Agents.await(routine.id, :paused, 2_000)
      assert %InboxWake{state: "pending", blocked_by: "paused"} = InboxWakes.get(routine.id)

      Agents.resume_agent(routine.id)
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)
      assert :ok = perform(wake)
      assert_receive {:enqueued, ^provider, _args, meta}, 1_000
      assert meta["correlation_id"] =~ "inbox:#{wake.wake_id}:"
    end
  end

  test "an approval gate retains the claim until the gate clears" do
    routine = routine_fixture!(tmp_workspace!())
    start_stub!(routine, :claude)

    assert :processing = Agents.submit_prompt(routine.id, "propose")
    assert_receive {:enqueued, :claude, _args, current_meta}

    finish_turn(
      :claude,
      current_meta,
      ObanClaude.Testing.structured_result(%{
        "directive" => "request_permission",
        "action" => "change it"
      })
    )

    assert {:ok, {:awaiting_permission, action}} =
             Agents.await(routine.id, :awaiting_permission, 1_000)

    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    assert :ok = perform(wake)

    eventually(fn ->
      assert %InboxWake{state: "pending", blocked_by: "awaiting_permission"} =
               InboxWakes.get(routine.id)
    end)

    assert :rejected = Agents.reject_action(routine.id, action.id, "test")
    assert :ok = perform(wake)
    assert_receive {:enqueued, :claude, _args, inbox_meta}, 1_000
    assert inbox_meta["correlation_id"] =~ "inbox:#{wake.wake_id}:"
    eventually(fn -> assert InboxWakes.get(routine.id) == nil end)
  end

  test "an offline routine over its daily rail boots paused without a leak turn" do
    routine = routine_fixture!(tmp_workspace!(), %{daily_budget_usd: 0.1})
    :ok = SpendLedger.record(routine.id, 5.0)
    assert {:ok, :offline} = Agents.status(routine.id)

    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    assert :ok = perform(wake)

    assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)

    assert %InboxWake{state: "pending", blocked_by: "spend_rail"} =
             InboxWakes.get(routine.id)

    refute_receive {:enqueued, :claude, _args, _meta}, 50

    on_exit(fn -> Agents.stop_agent(routine.id, :claude) end)
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: a rail crossed after claim pauses inside handoff without a self-call" do
      provider = unquote(provider)

      routine =
        routine_fixture!(tmp_workspace!(), %{provider: provider, daily_budget_usd: 0.1})

      on_exit(fn ->
        Agents.stop_agent(routine.id, provider)
        AgentHandoffIntent.clear(routine.id)
      end)

      assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

      assert :ok =
               InboxWakes.dispatch(routine.id, wake.wake_id,
                 before_claim: fn ->
                   assert :ok = SpendLedger.record(routine.id, 5.0)
                 end
               )

      assert {:ok, :paused} = Agents.await(routine.id, provider, :paused, 1_000)

      assert {:ok,
              %{
                state: :paused,
                pause_context: %{cause: :emergency_pause, reason: :spend_rail}
              }} = Agents.info(routine.id, provider)

      assert Process.alive?(Process.whereis(AgentHandoff))

      eventually(fn ->
        assert %InboxWake{state: "pending", blocked_by: "spend_rail"} =
                 InboxWakes.get(routine.id)
      end)

      refute_receive {:enqueued, ^provider, _args, _meta}, 50
    end
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: explicit resume authorizes exactly one retained over-rail wake" do
      provider = unquote(provider)

      routine =
        routine_fixture!(tmp_workspace!(), %{provider: provider, daily_budget_usd: 0.1})

      start_stub!(routine, provider)
      :ok = SpendLedger.record(routine.id, 5.0)

      assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
      assert :ok = perform(wake)
      assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)

      assert %InboxWake{
               state: "pending",
               blocked_by: "spend_rail",
               spend_override: false
             } = InboxWakes.get(routine.id)

      Agents.resume_agent(routine.id)
      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)

      eventually(fn ->
        assert %InboxWake{state: "pending", blocked_by: nil, spend_override: true} =
                 InboxWakes.get(routine.id)
      end)

      assert :ok = perform(wake)
      assert_receive {:enqueued, ^provider, _args, inbox_meta}, 1_000
      assert inbox_meta["correlation_id"] =~ "inbox:#{wake.wake_id}:"
      eventually(fn -> assert InboxWakes.get(routine.id) == nil end)

      assert :ok = perform(wake)
      refute_receive {:enqueued, ^provider, _args, _meta}, 100
    end
  end

  test "boot reconciliation clears an admitted wake before applying the spend rail" do
    routine = routine_fixture!(tmp_workspace!(), %{daily_budget_usd: 0.1})
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    claim_token = Ecto.UUID.generate()

    job =
      insert_provider_job!(
        :claude,
        %{"prompt" => routine.prompt},
        %{
          "agent_id" => routine.id,
          "correlation_id" => "inbox:#{wake.wake_id}:#{claim_token}"
        }
      )

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    :ok = SpendLedger.record(routine.id, 5.0)

    assert :ok = InboxWakes.reconcile!()
    assert InboxWakes.get(routine.id) == nil
    assert {:ok, :offline} = Agents.status(routine.id)
  end

  test "a later note starts a new wave after the debounce cutoff is claimed" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, claimed} = InboxWakes.request(routine, debounce_seconds: 0)
    claim_token = Ecto.UUID.generate()

    claimed
    |> InboxWake.update_changeset(%{
      state: "dispatching",
      claim_token: claim_token,
      claimed_at: DateTime.utc_now()
    })
    |> Repo.update!()

    assert {:ok, later} = InboxWakes.request(routine, debounce_seconds: 20)
    refute later.wake_id == claimed.wake_id
    assert later.note_count == 1
    assert later.state == "pending"

    assert :ok =
             InboxWakes.handle_event(
               [:oban_claude, :agent, :transition],
               %{},
               %{
                 agent_id: routine.id,
                 from: :idle,
                 to: :running,
                 correlation_id: "inbox:#{claimed.wake_id}:#{claim_token}"
               },
               nil
             )

    assert %InboxWake{wake_id: wake_id, state: "pending"} = InboxWakes.get(routine.id)
    assert wake_id == later.wake_id
  end

  test "boot reconciliation conservatively requires another resume for an over-rail override" do
    routine = routine_fixture!(tmp_workspace!(), %{daily_budget_usd: 0.1})
    start_stub!(routine, :claude)
    :ok = SpendLedger.record(routine.id, 5.0)

    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    assert :ok = perform(wake)
    assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)

    Agents.resume_agent(routine.id)
    assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)

    eventually(fn ->
      assert %InboxWake{spend_override: true} = InboxWakes.get(routine.id)
    end)

    # Full boot order restores the budget pause first. The override stays on
    # the one wake, but the operator must explicitly resume the new process.
    assert :ok = SpendLedger.reconcile_pauses!()
    assert :ok = InboxWakes.reconcile!()
    assert {:ok, :paused} = Agents.await(routine.id, :paused, 1_000)
    assert %InboxWake{spend_override: true} = InboxWakes.get(routine.id)
    refute_receive {:enqueued, :claude, _args, _meta}, 100
  end

  for provider <- [:claude, :codex] do
    test "#{provider}: a replacement waits for the previous generation's durable job" do
      provider = unquote(provider)
      routine = routine_fixture!(tmp_workspace!(), %{provider: provider})
      pid = start_stub!(routine, provider)

      assert :processing = Agents.submit_prompt(routine.id, "current turn")
      assert_receive {:enqueued, ^provider, current_args, current_meta}
      old_job = insert_provider_job!(provider, current_args, current_meta)

      assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
      assert :ok = perform(wake)

      eventually(fn ->
        assert %InboxWake{state: "pending", blocked_by: "running"} =
                 InboxWakes.get(routine.id)
      end)

      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 1_000

      assert {:ok, :idle} = Agents.await(routine.id, :idle, 1_000)
      assert :ok = perform(wake)

      eventually(fn ->
        assert %InboxWake{state: "pending", claim_token: nil, blocked_by: "provider_job"} =
                 InboxWakes.get(routine.id)
      end)

      retry_at = DateTime.add(DateTime.utc_now(), 10, :second)

      refute_receive {:enqueued, ^provider, _args, _meta}, 50

      :ok = Oban.cancel_job(old_job.id)

      # Cancellation doesn't emit executor completion telemetry. The next
      # inbox event re-evaluates the durable job state and releases the hold.
      assert {:ok, retried} = InboxWakes.request(routine, debounce_seconds: 0)
      assert retried.wake_id == wake.wake_id
      assert retried.blocked_by == "debounce"
      assert :ok = InboxWakes.dispatch(routine.id, wake.wake_id, now: retry_at)

      assert_receive {:enqueued, ^provider, _args, retry_meta}, 1_000
      assert retry_meta["correlation_id"] =~ "inbox:#{wake.wake_id}:"
      eventually(fn -> assert InboxWakes.get(routine.id) == nil end)
    end
  end

  test "a provider job with this wake correlation proves admission after a process crash" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    claim_token = Ecto.UUID.generate()

    _job =
      insert_provider_job!(
        :claude,
        %{"prompt" => routine.prompt},
        %{
          "agent_id" => routine.id,
          "correlation_id" => "inbox:#{wake.wake_id}:#{claim_token}"
        }
      )

    assert :ok = InboxWakes.dispatch(routine.id, wake.wake_id)
    assert InboxWakes.get(routine.id) == nil
  end

  test "boot reconciliation recovers an orphaned claim and restores its kickoff" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake
    |> InboxWake.update_changeset(%{
      state: "dispatching",
      claim_token: Ecto.UUID.generate(),
      claimed_at: DateTime.utc_now(),
      blocked_by: "running"
    })
    |> Repo.update!()

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    assert wake_jobs(routine.id, wake.wake_id) == []

    assert :ok = InboxWakes.reconcile!()

    assert %InboxWake{state: "pending", claim_token: nil, claimed_at: nil} =
             InboxWakes.get(routine.id)

    assert [_job] = wake_jobs(routine.id, wake.wake_id)
  end

  test "a completed config handoff releases its held inbox wake" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    wake
    |> InboxWake.update_changeset(%{blocked_by: "config_transition", retry_count: 1})
    |> Repo.update!()

    assert :ok = InboxWakes.config_ready(routine.id)

    assert %InboxWake{blocked_by: nil, retry_count: 0} = InboxWakes.get(routine.id)
    assert [_job] = wake_jobs(routine.id, wake.wake_id)
  end

  test "a config handoff keeps its wake held when kickoff insertion fails" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    wake
    |> InboxWake.update_changeset(%{blocked_by: "config_transition", retry_count: 1})
    |> Repo.update!()

    assert {:error, {:enqueue_failed, :queue_unavailable}} =
             InboxWakes.config_ready(routine.id,
               enqueue: fn _wake -> {:error, :queue_unavailable} end
             )

    assert %InboxWake{blocked_by: "config_transition", retry_count: 1} =
             InboxWakes.get(routine.id)

    assert wake_jobs(routine.id, wake.wake_id) == []
  end

  test "a config handoff keeps its wake held when the release transaction fails" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    wake
    |> InboxWake.update_changeset(%{blocked_by: "config_transition", retry_count: 1})
    |> Repo.update!()

    assert {:error, :database_unavailable} =
             InboxWakes.config_ready(routine.id,
               transaction: fn _fun -> {:error, :database_unavailable} end
             )

    assert %InboxWake{blocked_by: "config_transition", retry_count: 1} =
             InboxWakes.get(routine.id)

    assert wake_jobs(routine.id, wake.wake_id) == []
  end

  test "provider-loss recovery crosses the ticks queue before starting an offline agent" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)

    wake_jobs(routine.id, wake.wake_id)
    |> Enum.each(fn job -> Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id)) end)

    assert {:ok, :offline} = Agents.status(routine.id)
    assert :ok = InboxWakes.provider_down(routine.id, wake.wake_id, nil)
    assert {:ok, :offline} = Agents.status(routine.id)
    assert [_job] = wake_jobs(routine.id, wake.wake_id)
  end

  test "an unrelated running transition cannot clear pending inbox work" do
    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 60)

    assert :ok =
             InboxWakes.handle_event(
               [:oban_claude, :agent, :transition],
               %{},
               %{
                 agent_id: routine.id,
                 from: :idle,
                 to: :running,
                 correlation_id: "operator-message"
               },
               nil
             )

    assert %InboxWake{wake_id: wake_id, state: "pending", blocked_by: "running"} =
             InboxWakes.get(routine.id)

    assert wake_id == wake.wake_id
  end

  test "ignore policy and removed routines deliberately supersede pending work" do
    quiet = routine_fixture!(tmp_workspace!(), %{on_note: :ignore})
    assert {:error, :ignored} = InboxWakes.request(quiet, debounce_seconds: 0)
    assert InboxWakes.get(quiet.id) == nil

    routine = routine_fixture!(tmp_workspace!())
    assert {:ok, wake} = InboxWakes.request(routine, debounce_seconds: 0)
    put_env!(:routines, [])

    assert :ok = perform(wake)
    assert InboxWakes.get(routine.id) == nil
  end

  defp start_stub!(routine, provider) do
    test_pid = self()

    config =
      routine
      |> Custode.Routine.agent_config(%{})
      |> Keyword.put(
        :enqueue_fun,
        fn args, meta ->
          send(test_pid, {:enqueued, provider, args, meta})
          {:ok, :queued}
        end
      )

    {:ok, pid} = Agents.start_agent(routine.id, config)

    on_exit(fn -> Agents.stop_agent(routine.id, provider) end)
    pid
  end

  defp insert_provider_job!(provider, args, meta) do
    worker = if provider == :claude, do: ObanClaude.Agent.Job, else: ObanCodex.Agent.Job
    {:ok, job} = args |> worker.new(meta: meta) |> Oban.insert()
    job
  end

  defp finish_turn(provider, meta, result \\ nil)

  defp finish_turn(:claude, meta, nil),
    do: finish_turn(:claude, meta, ObanClaude.Testing.result(session_id: Ecto.UUID.generate()))

  defp finish_turn(:claude, meta, result) do
    ObanClaude.Agent.Job.handle_result(result, %Oban.Job{meta: meta, attempt: 1, max_attempts: 1})
  end

  defp finish_turn(:codex, meta, nil) do
    result = ObanCodex.Testing.result(session_id: Ecto.UUID.generate())
    ObanCodex.Agent.Job.handle_result(result, %Oban.Job{meta: meta, attempt: 1, max_attempts: 1})
  end

  defp perform(wake) do
    InboxWakeJob.perform(%Oban.Job{
      args: %{"routine_id" => wake.routine_id, "wake_id" => wake.wake_id}
    })
  end

  defp wake_jobs(routine_id, wake_id) do
    "Custode.InboxWakeJob"
    |> jobs_for()
    |> Enum.filter(fn job ->
      job.args["routine_id"] == routine_id and job.args["wake_id"] == wake_id
    end)
  end
end
