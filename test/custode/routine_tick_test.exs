defmodule Custode.RoutineTickTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.RoutineTick

  defmodule WorkIntake do
    def on_routine_tick(routine) do
      send(Application.fetch_env!(:custode, :routine_tick_test_pid), {:intake, routine})
      Application.fetch_env!(:custode, :routine_tick_test_result)
    end
  end

  defmodule WorkVertical do
    def schedule(routine, results) do
      send(Application.fetch_env!(:custode, :routine_tick_test_pid), {
        :vertical,
        routine,
        results
      })

      {:ok, [:scheduled]}
    end
  end

  # the Tick jobs RoutineTick enqueues for one agent, newest first (queues
  # are empty in test config, so they insert and sit there for inspection;
  # the oban_jobs table is shared across the suite, so always scope by id)
  defp ticks_for(agent_id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "ObanClaude.Agent.Tick",
        where: fragment("json_extract(?, '$.agent_id')", j.args) == ^agent_id,
        order_by: [desc: j.id]
      )
    )
  end

  test "resolves the routine's current args at fire time, not at boot" do
    workspace = tmp_workspace!()
    id = uid("drift")

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "original", model: "haiku"}
    ])

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})

    first = hd(ticks_for(id))
    assert first.args["agent_id"] == id
    assert first.args["prompt"] == "original"
    assert first.args["start"]["args"]["model"] == "haiku"

    # edit the routine's prompt and model WITHOUT restarting: the next fire
    # must pick up the new config (the whole point of #7)
    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "revised", model: "sonnet"}
    ])

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})

    second = hd(ticks_for(id))
    assert second.id != first.id
    assert second.args["prompt"] == "revised"
    assert second.args["start"]["args"]["model"] == "sonnet"
  end

  test "a beat that waited out a withheld queue cancels itself and inserts nothing (#442)" do
    workspace = tmp_workspace!()
    id = uid("stale")

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "sweep", model: "haiku"}
    ])

    queued_days_ago = DateTime.add(DateTime.utc_now(), -3 * 86_400, :second)

    assert {:cancel, {:stale_tick, ^id}} =
             RoutineTick.perform(%Oban.Job{
               args: %{"routine_id" => id},
               scheduled_at: queued_days_ago,
               inserted_at: queued_days_ago
             })

    assert ticks_for(id) == []

    # the same beat a few seconds late is just a beat
    just_now = DateTime.add(DateTime.utc_now(), -5, :second)

    assert :ok =
             RoutineTick.perform(%Oban.Job{
               args: %{"routine_id" => id},
               scheduled_at: just_now,
               inserted_at: just_now
             })

    assert [_tick] = ticks_for(id)
  end

  describe "a provider limit held by its reset time (#525)" do
    setup do
      Custode.Availability.forget("claude")
      on_exit(fn -> Custode.Availability.forget("claude") end)

      id = uid("held")

      put_env!(:routines, [
        %{id: id, cron: "@daily", workspace: tmp_workspace!(), prompt: "sweep", model: "haiku"}
      ])

      %{id: id}
    end

    # a rejection observed 40 minutes ago: stale, and only its reset holds
    defp reject_until(seconds_from_now) do
      now = DateTime.utc_now()

      Custode.Availability.put(%Custode.Availability.Snapshot{
        provider: "claude",
        source: "test",
        observed_at: DateTime.add(now, -2400, :second),
        buckets: [
          %Custode.Availability.Bucket{
            id: "five_hour",
            status: :rejected,
            resets_at: DateTime.add(now, seconds_from_now, :second)
          }
        ]
      })
    end

    test "a reset inside the stale-tick window snoozes to just past it", %{id: id} do
      reject_until(120)

      assert {:snooze, seconds} = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})
      assert seconds in 145..155
      assert ticks_for(id) == []

      assert %{"event" => "beat_deferred", "summary" => summary} = Custode.Feed.last_for(id)
      assert summary =~ "claude is limited until"
    end

    test "a reset beyond the window is a missed beat, not a replay hours later", %{id: id} do
      reject_until(7200)

      assert {:cancel, {:provider_limited, ^id, %DateTime{}}} =
               RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})

      assert ticks_for(id) == []
      assert %{"event" => "beat_deferred", "summary" => summary} = Custode.Feed.last_for(id)
      assert summary =~ "this beat is missed"
    end

    test "the window is measured from when the beat was due", %{id: id} do
      reject_until(120)
      due = DateTime.add(DateTime.utc_now(), -500, :second)

      assert {:cancel, {:provider_limited, ^id, _until}} =
               RoutineTick.perform(%Oban.Job{
                 args: %{"routine_id" => id},
                 scheduled_at: due,
                 inserted_at: due
               })
    end

    test "a reset that has passed beats as usual", %{id: id} do
      reject_until(-60)

      assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})
      assert [_tick] = ticks_for(id)
    end

    test "a manual beat inserts its Tick directly and is never deferred", %{id: id} do
      reject_until(7200)

      assert {:ok, _job_id} = Custode.beat(id)
      assert [_tick] = ticks_for(id)
    end
  end

  test "cancels when the routine no longer exists" do
    ghost = uid("ghost")

    assert {:cancel, {:unknown_routine, ^ghost}} =
             RoutineTick.perform(%Oban.Job{args: %{"routine_id" => ghost}})

    assert ticks_for(ghost) == []
  end

  test "cancels on a malformed job with no routine_id" do
    assert {:cancel, {:invalid_routine_tick, _}} =
             RoutineTick.perform(%Oban.Job{args: %{}})
  end

  test "intake is a failure-isolated sidecar and does not change the legacy tick" do
    workspace = tmp_workspace!()
    id = uid("intake")

    put_env!(:routines, [
      %{
        id: id,
        cron: "@daily",
        workspace: workspace,
        prompt: "unchanged prompt",
        model: "haiku"
      }
    ])

    put_env!(:work_intake, WorkIntake)
    put_env!(:routine_tick_test_pid, self())
    put_env!(:routine_tick_test_result, {:error, :github_unavailable})

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})
    assert_receive {:intake, %{id: ^id, prompt: "unchanged prompt"}}

    assert [job] = ticks_for(id)
    assert job.args == Custode.Routine.tick_args(Custode.Routine.get(id))
    assert job.args["prompt"] == "unchanged prompt"
    assert job.args["start"]["args"]["model"] == "haiku"
  end

  test "eligible intake schedules the bounded vertical and preserves the legacy tick" do
    workspace = tmp_workspace!()
    id = uid("vertical")
    result = %{work_item: %{work_item_id: "work-368", state: "ready", phase: "eligible"}}

    put_env!(:routines, [
      %{id: id, cron: "@daily", workspace: workspace, prompt: "legacy sweep", model: "haiku"}
    ])

    put_env!(:work_intake, WorkIntake)
    put_env!(:work_vertical, WorkVertical)
    put_env!(:routine_tick_test_pid, self())
    put_env!(:routine_tick_test_result, {:ok, [result]})

    assert :ok = RoutineTick.perform(%Oban.Job{args: %{"routine_id" => id}})
    assert_receive {:intake, %{id: ^id}}
    assert_receive {:vertical, %{id: ^id}, [^result]}

    assert [job] = ticks_for(id)
    assert job.args["prompt"] == "legacy sweep"
  end
end
