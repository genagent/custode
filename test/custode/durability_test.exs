defmodule Custode.DurabilityTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Sensors.Deadman
  alias ObanClaude.Agent

  describe "budget reconcile (#6)" do
    test "an over-rail routine boots PAUSED after restart; within-rail boots nothing" do
      workspace = tmp_workspace!()
      over = routine_fixture!(workspace, %{daily_budget_usd: 1.0})
      :ok = Custode.SpendLedger.record(over.id, 2.0, "turn")
      on_exit(fn -> Agent.stop_agent(over.id) end)

      :ok = Custode.SpendLedger.reconcile_pauses!()

      {:ok, :paused} = Agent.await(over.id, :paused, 1_000)

      # the pause is a cast and the feed row is written after it (#257)
      eventually(fn ->
        assert Enum.any?(
                 Custode.Feed.for_agent(over.id),
                 &(&1["event"] == "budget_paused" and &1["action"] =~ "no leak turn")
               )
      end)

      # a fresh routine under its rail is untouched (stays offline)
      fresh = routine_fixture!(workspace, %{daily_budget_usd: 100.0})
      :ok = Custode.SpendLedger.reconcile_pauses!()
      {:ok, :offline} = Agent.status(fresh.id)
    end
  end

  describe "idle sub-agent GC (#16)" do
    test "stale idle ephemerals are reaped; fresh and routine agents survive" do
      stale = start_stub_agent!()
      fresh = start_stub_agent!()

      Custode.Feed.record(%{event: "turn", agent: stale, summary: "long ago"})
      Custode.Feed.record(%{event: "turn", agent: fresh, summary: "just now"})

      old = DateTime.utc_now() |> DateTime.add(-10_000) |> DateTime.to_iso8601()

      Custode.Repo.query!(
        "UPDATE feed_entries SET at = ? WHERE agent = ?",
        [old, stale]
      )

      :ok = Custode.Janitor.perform(%Oban.Job{args: %{}})

      # registry cleanup is async
      Enum.find(1..50, fn _attempt ->
        Process.sleep(20)
        not Enum.any?(Agent.list(), fn {id, _s} -> id == stale end)
      end) || flunk("stale ephemeral was not reaped")

      assert Enum.any?(Agent.list(), fn {id, _s} -> id == fresh end)
    end
  end

  describe "rejection learning" do
    test "a rejected proposal lands in the routine's inbox with the reason" do
      import ObanClaude.Testing

      workspace = tmp_workspace!()
      routine = routine_fixture!(workspace)
      test_pid = self()

      {:ok, _pid} =
        Agent.start_agent(routine.id,
          enqueue_fun: fn _a, _m ->
            send(test_pid, :enqueued)
            {:ok, :queued}
          end
        )

      on_exit(fn -> Agent.stop_agent(routine.id) end)

      :processing = Agent.submit_prompt(routine.id, "go")

      :ok =
        Agent.job_finished(
          routine.id,
          {:ok,
           structured_result(%{"directive" => "request_permission", "action" => "delete it all"})}
        )

      {:ok, {:awaiting_permission, action}} = Agent.await(routine.id, :awaiting_permission, 1_000)

      :rejected = Custode.reject_with_note(routine.id, action.id, "too destructive, never this")

      assert [note] = Path.wildcard(Path.join([workspace, "inbox", "rejection-*"]))
      content = File.read!(note)
      assert content =~ "REJECTED"
      assert content =~ "delete it all"
      assert content =~ "too destructive, never this"
      assert content =~ "REMEMBER"
    end
  end

  describe "deadman (#3)" do
    test "a silent sensor notes the meta-agent; fresh and never-seen sensors do not" do
      workspace = tmp_workspace!()
      meta = routine_fixture!(workspace)

      put_env!(:sensors, [
        %{id: "dead-one", cron: "*/15 * * * *", module: Custode.Sensors.CiStatus, notify: "x"},
        %{id: "alive-one", cron: "*/15 * * * *", module: Custode.Sensors.CiStatus, notify: "x"},
        %{id: "never-one", cron: "*/15 * * * *", module: Custode.Sensors.CiStatus, notify: "x"}
      ])

      Custode.Feed.record(%{event: "sensor", agent: "x", sensor_id: "dead-one", summary: "old"})

      old = DateTime.utc_now() |> DateTime.add(-3 * 3600) |> DateTime.to_iso8601()

      Custode.Repo.query!(
        "UPDATE feed_entries SET at = ? WHERE json_extract(entry, '$.sensor_id') = 'dead-one'",
        [old]
      )

      Custode.Feed.record(%{event: "sensor", agent: "x", sensor_id: "alive-one", summary: "hi"})

      :ok =
        Deadman.perform(%Oban.Job{
          args: %{"sensor_id" => uid("deadman"), "notify" => meta.id}
        })

      assert [note] = Path.wildcard(Path.join([workspace, "inbox", "sensor-*"]))
      content = File.read!(note)
      assert content =~ "dead-one: silent"
      refute content =~ "alive-one"
      refute content =~ "never-one"
    end

    test "cron cadences parse" do
      assert Deadman.interval_minutes("*/15 * * * *") == 15
      assert Deadman.interval_minutes("@daily") == 1_440
      assert Deadman.interval_minutes("@hourly") == 60
      assert Deadman.interval_minutes("0 3 * * *") == 60
    end
  end
end
