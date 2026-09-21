defmodule Custode.SchedulerTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import Custode.TestHelpers

  alias Custode.NextBeat
  alias Custode.Repo
  alias Custode.Scheduler

  # A DateTime at a fixed wall-clock minute (UTC), seconds/micros settable so
  # a test can walk across a minute boundary.
  defp at(hour, minute, second \\ 0, micro \\ 0) do
    %DateTime{
      year: 2026,
      month: 7,
      day: 21,
      hour: hour,
      minute: minute,
      second: second,
      microsecond: {micro, 6},
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }
  end

  # A mutable clock the test advances by hand, torn down defensively (it is
  # linked to the test, so on_exit may find it already gone).
  defp start_clock!(dt) do
    {:ok, ref} = Agent.start_link(fn -> dt end)
    on_exit(fn -> stop(ref) end)
    ref
  end

  defp set_now(ref, dt), do: Agent.update(ref, fn _ -> dt end)

  # A scheduler whose clock and insert are driven by the test: `insert` sends
  # each fired routine id to the test mailbox. No timer (autostart: false), so
  # every fire is an explicit tick/1 with a controlled clock.
  defp start_scheduler!(now_ref) do
    test = self()

    {:ok, pid} =
      Scheduler.start_link(
        name: nil,
        autostart: false,
        clock: fn -> Agent.get(now_ref, & &1) end,
        insert_job: fn changeset ->
          args = Ecto.Changeset.get_field(changeset, :args)
          send(test, {:fired, args["routine_id"]})
          {:ok, %Oban.Job{args: args}}
        end
      )

    on_exit(fn -> stop(pid) end)
    pid
  end

  defp start_durable_scheduler!(now_ref, opts \\ []) do
    {:ok, pid} =
      Scheduler.start_link(
        [
          name: nil,
          autostart: false,
          clock: fn -> Agent.get(now_ref, & &1) end
        ] ++ opts
      )

    on_exit(fn -> stop(pid) end)
    pid
  end

  defp stop(pid) do
    if Process.alive?(pid) do
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end
  end

  defp routine(id, cron), do: %{id: id, cron: cron, workspace: tmp_workspace!(), prompt: "go"}

  describe "due/3 (pure expression matching)" do
    test "fires only the routines whose cron matches the minute" do
      routines = [
        %{id: "every-min", cron: "* * * * *"},
        %{id: "top-of-hour", cron: "0 * * * *"},
        %{id: "daily-midnight", cron: "@daily"}
      ]

      # 09:00 -- both the every-minute and the top-of-hour routine match
      {fired, _seen} = Scheduler.due(routines, at(9, 0), %{})
      assert Enum.sort(fired) == ["every-min", "top-of-hour"]

      # 09:30 -- only the every-minute routine matches
      {fired, _seen} = Scheduler.due(routines, at(9, 30), %{})
      assert fired == ["every-min"]
    end

    test "does not refire a routine already fired this minute (drift guard)" do
      routines = [%{id: "r", cron: "* * * * *"}]

      {fired, seen} = Scheduler.due(routines, at(9, 0, 0), %{})
      assert fired == ["r"]

      # a second evaluation a few hundred ms later, same wall-clock minute:
      # the last_fired map suppresses the duplicate insert
      {fired, seen} = Scheduler.due(routines, at(9, 0, 40, 500_000), seen)
      assert fired == []

      # the next minute fires again
      {fired, _seen} = Scheduler.due(routines, at(9, 1, 0), seen)
      assert fired == ["r"]
    end

    test "@reboot routines are never due on a minute match" do
      routines = [%{id: "boot", cron: "@reboot"}]
      {fired, _seen} = Scheduler.due(routines, at(9, 0), %{})
      assert fired == []
    end
  end

  describe "the running scheduler" do
    test "a tick fires the matching routine, and the same minute does not double-fire" do
      now_ref = start_clock!(at(9, 0, 0))

      put_env!(:routines, [routine("every", "* * * * *")])
      pid = start_scheduler!(now_ref)

      assert Scheduler.tick(pid) == ["every"]
      assert_received {:fired, "every"}

      # advance within the same minute: no second insert
      set_now(now_ref, at(9, 0, 55, 900_000))
      assert Scheduler.tick(pid) == []
      refute_received {:fired, "every"}

      # cross the boundary: fires again
      set_now(now_ref, at(9, 1, 2))
      assert Scheduler.tick(pid) == ["every"]
      assert_received {:fired, "every"}
    end

    test "cron: :manual routines are never fired" do
      now_ref = start_clock!(at(9, 0, 0))

      put_env!(:routines, [Map.put(routine("manual", "* * * * *"), :cron, :manual)])
      pid = start_scheduler!(now_ref)

      assert Scheduler.tick(pid) == []
      refute_received {:fired, "manual"}
    end

    test "a roster edit is reflected on the very next tick (no restart)" do
      now_ref = start_clock!(at(9, 0, 0))

      # a routine scheduled at the top of the hour only: does not fire at 09:30
      put_env!(:routines, [routine("r", "0 * * * *")])
      pid = start_scheduler!(now_ref)

      set_now(now_ref, at(9, 30, 0))
      assert Scheduler.tick(pid) == []

      # edit its cadence to every minute WITHOUT restarting the scheduler: the
      # next tick reads the fresh roster and fires it (the whole point of #142)
      put_env!(:routines, [routine("r", "* * * * *")])
      assert Scheduler.tick(pid) == ["r"]
      assert_received {:fired, "r"}
    end

    test "hour-anchored routines fire on the local hour, not the UTC one" do
      # 09:00 America/Los_Angeles is 16:00 UTC in July (PDT, UTC-7). The clock
      # hands the scheduler a PT-zoned DateTime, the way the default clock does
      # (config :timezone is America/Los_Angeles, #17). An expression anchored
      # to the LOCAL 9am must fire; one anchored to the UTC 16:00 -- the same
      # instant -- must NOT, proving evaluation reads the local wall clock.
      pt_9am = DateTime.new!(~D[2026-07-21], ~T[09:00:00], "America/Los_Angeles")
      assert pt_9am.hour == 9
      assert DateTime.to_iso8601(DateTime.shift_zone!(pt_9am, "Etc/UTC")) =~ "T16:00:00"

      now_ref = start_clock!(pt_9am)

      put_env!(:routines, [
        routine("local-9am", "0 9 * * *"),
        routine("utc-hour", "0 16 * * *")
      ])

      pid = start_scheduler!(now_ref)

      assert Scheduler.tick(pid) == ["local-9am"]
      assert_received {:fired, "local-9am"}
      refute_received {:fired, "utc-hour"}
    end

    test "@reboot routines fire once at boot, then never on a minute tick" do
      now_ref = start_clock!(at(0, 0, 0))

      put_env!(:routines, [routine("boot", "@reboot")])
      pid = start_scheduler!(now_ref)

      # the boot insert happened during init, before any tick
      assert_received {:fired, "boot"}

      # a minute tick does not fire it again
      set_now(now_ref, at(0, 1, 0))
      assert Scheduler.tick(pid) == []
      refute_received {:fired, "boot"}
    end
  end

  describe "durable handoff" do
    test "ordinary cron is unique across a same-minute scheduler restart" do
      id = uid("cron-restart")
      now_ref = start_clock!(at(9, 0, 0))
      cleanup_schedule!(id)
      put_env!(:routines, [routine(id, "* * * * *")])

      first = start_durable_scheduler!(now_ref)
      assert Scheduler.tick(first) == [id]
      stop(first)

      second = start_durable_scheduler!(now_ref)
      assert Scheduler.tick(second) == []

      assert [job] = scheduled_jobs(id)
      assert job.args["schedule_occurrence"] =~ "cron:#{id}:"
      assert job.conflict? == false
    end

    test "a requested beat inserts and consumes the observed request atomically" do
      id = uid("requested")
      now_ref = start_clock!(at(9, 10, 0))
      cleanup_schedule!(id)
      put_env!(:routines, [routine(id, "0 0 * * *")])
      assert {:ok, _granted} = NextBeat.request(id, 5, now: at(9, 0, 0))

      scheduler = start_durable_scheduler!(now_ref)
      assert Scheduler.tick(scheduler) == [id]
      assert NextBeat.get(id) == nil

      assert [job] = scheduled_jobs(id)
      assert job.args["schedule_occurrence"] =~ "requested:#{id}:"
    end

    test "an enqueue exception preserves the request and the next tick retries it" do
      id = uid("enqueue-failure")
      now_ref = start_clock!(at(9, 10, 0))
      cleanup_schedule!(id)
      put_env!(:routines, [routine(id, "0 0 * * *")])
      assert {:ok, _granted} = NextBeat.request(id, 5, now: at(9, 0, 0))
      {:ok, attempts} = Agent.start_link(fn -> 0 end)
      on_exit(fn -> stop(attempts) end)

      insert_job = fn changeset ->
        case Agent.get_and_update(attempts, &{&1, &1 + 1}) do
          0 -> raise "injected enqueue failure"
          _retry -> Oban.insert(changeset)
        end
      end

      scheduler = start_durable_scheduler!(now_ref, insert_job: insert_job)
      assert Scheduler.tick(scheduler) == []
      assert %NextBeat{} = NextBeat.get(id)
      assert scheduled_jobs(id) == []

      assert Scheduler.tick(scheduler) == [id]
      assert NextBeat.get(id) == nil
      assert length(scheduled_jobs(id)) == 1
    end

    test "a replacement request is not consumed with an older snapshot" do
      id = uid("replacement")
      now_ref = start_clock!(at(9, 10, 0))
      cleanup_schedule!(id)
      put_env!(:routines, [routine(id, "0 0 * * *")])
      assert {:ok, _granted} = NextBeat.request(id, 5, now: at(9, 0, 0))
      observed = NextBeat.get(id)

      requested = fn ->
        assert {:ok, _granted} = NextBeat.request(id, 60, now: at(9, 10, 0))
        %{id => observed}
      end

      scheduler = start_durable_scheduler!(now_ref, requested: requested)
      assert Scheduler.tick(scheduler) == []
      assert %NextBeat{at: at} = NextBeat.get(id)
      assert at == at(10, 10, 0)
      assert scheduled_jobs(id) == []
    end

    test "@reboot remains one insertion per scheduler boot" do
      id = uid("reboot")
      now_ref = start_clock!(at(9, 0, 0))
      cleanup_schedule!(id)
      put_env!(:routines, [routine(id, "@reboot")])

      first = start_durable_scheduler!(now_ref)
      stop(first)
      _second = start_durable_scheduler!(now_ref)

      assert length(scheduled_jobs(id)) == 2
      assert Enum.all?(scheduled_jobs(id), &(&1.args["schedule_source"] == "reboot"))
    end
  end

  describe "next_beat_at/2" do
    test "the next matching minute after now, in UTC" do
      assert Scheduler.next_beat_at("*/15 * * * *", ~U[2026-09-20 10:07:30Z]) ==
               ~U[2026-09-20 10:15:00Z]

      # a minute that matches right now is this beat, not the next one
      assert Scheduler.next_beat_at("*/15 * * * *", ~U[2026-09-20 10:15:00Z]) ==
               ~U[2026-09-20 10:30:00Z]
    end

    test "evaluated on the local wall clock, the same as the scheduler fires (#17)" do
      put_env!(:timezone, "America/Los_Angeles")

      # @daily is the operator's midnight: 07:00 UTC while PDT is in force
      assert Scheduler.next_beat_at("@daily", ~U[2026-09-20 10:00:00Z]) ==
               ~U[2026-09-21 07:00:00Z]

      # working hours only: after 18:00 local the next beat is tomorrow's 09:00
      assert Scheduler.next_beat_at("*/30 9-18 * * *", ~U[2026-09-21 02:10:00Z]) ==
               ~U[2026-09-21 16:00:00Z]
    end

    test "nil when there is no next beat to know" do
      assert Scheduler.next_beat_at("@reboot") == nil
      assert Scheduler.next_beat_at("manual") == nil
      assert Scheduler.next_beat_at("") == nil
      assert Scheduler.next_beat_at(nil) == nil
    end
  end

  defp cleanup_schedule!(id) do
    on_exit(fn ->
      NextBeat.clear(id)

      Repo.delete_all(
        from(j in Oban.Job,
          where: j.worker == "Custode.RoutineTick",
          where: fragment("json_extract(?, '$.routine_id')", j.args) == ^id
        )
      )
    end)
  end

  defp scheduled_jobs(id) do
    Repo.all(
      from(j in Oban.Job,
        where: j.worker == "Custode.RoutineTick",
        where: fragment("json_extract(?, '$.routine_id')", j.args) == ^id,
        order_by: [asc: j.id]
      )
    )
  end
end
