defmodule Custode.SchedulerTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

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
        insert: fn id -> send(test, {:fired, id}) end
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
end
