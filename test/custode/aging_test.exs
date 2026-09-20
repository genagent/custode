defmodule Custode.AgingTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.Aging
  alias Custode.Asks.Ask
  alias Custode.Gates.Gate
  alias Custode.Repo

  doctest Custode.Aging

  @now ~U[2026-09-19 12:00:00.000000Z]
  @interval 600

  setup do
    path = Path.join(System.tmp_dir!(), uid("aging") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    # `due/2` reads every open gate and ask, so this module owns both tables
    Repo.query!("DELETE FROM gates")
    Repo.query!("DELETE FROM asks")
    Custode.Presence.set(:auto)
    on_exit(fn -> Custode.Presence.set(:auto) end)
    :ok
  end

  defp gate!(agent_id, age_s, attrs \\ []) do
    at = DateTime.add(@now, -age_s, :second)

    Repo.insert!(
      struct!(
        %Gate{
          agent_id: agent_id,
          kind: "approval",
          action_id: uid("act"),
          detail: "merge #294",
          inserted_at: at,
          updated_at: at
        },
        attrs
      )
    )
  end

  defp ask!(agent_id, age_s) do
    at = DateTime.add(@now, -age_s, :second)

    Repo.insert!(%Ask{
      agent_id: agent_id,
      question: "is the diff yours?",
      inserted_at: at,
      updated_at: at
    })
  end

  defp aging_entries(agent_id) do
    Repo.all(
      from(f in Custode.Feed.Entry,
        where: f.agent == ^agent_id and f.event in ["gate_aging", "ask_aging"],
        order_by: [asc: f.id]
      )
    )
    |> Enum.map(&Jason.decode!(&1.entry))
  end

  describe "crossed/2" do
    test "fires once per threshold, in the one window the age crosses it" do
      assert Aging.crossed(3_599, @interval) == nil
      assert Aging.crossed(3_600, @interval) == 3_600
      assert Aging.crossed(4_199, @interval) == 3_600
      # the next run, ten minutes on, is past it
      assert Aging.crossed(4_200, @interval) == nil
    end

    test "backs off: 1h, 4h, 24h" do
      assert Aging.crossed(2 * 3_600, @interval) == nil
      assert Aging.crossed(4 * 3_600 + 60, @interval) == 14_400
      assert Aging.crossed(12 * 3_600, @interval) == nil
      assert Aging.crossed(86_400 + 60, @interval) == 86_400
    end

    test "after the last threshold it repeats at that period, not faster" do
      assert Aging.crossed(86_400 + 3_600, @interval) == nil
      assert Aging.crossed(2 * 86_400 + 60, @interval) == 172_800
      assert Aging.crossed(3 * 86_400 + 599, @interval) == 259_200
    end

    test "the thresholds are configurable" do
      put_env!(:aging_thresholds_seconds, [900])
      assert Aging.crossed(900, @interval) == 900
      assert Aging.crossed(1_800, @interval) == 1_800
      assert Aging.crossed(3_600, @interval) == 3_600
    end
  end

  describe "run/2" do
    test "a gate that just passed an hour is said again, with its age and what it is" do
      agent = uid("redis-tower")
      gate!(agent, 3_600 + 120)

      assert Aging.run(@now, @interval) == 1

      assert [entry] = aging_entries(agent)
      assert entry["event"] == "gate_aging"
      assert entry["summary"] =~ "has waited 1h"
      assert entry["summary"] =~ "merge #294"
    end

    test "a fresh gate, a gate between thresholds, and a resolved gate are quiet" do
      agent = uid("quiet")
      gate!(agent, 120)
      gate!(agent, 2 * 3_600)
      gate!(agent, 3_600 + 60, status: "resolved")

      assert Aging.run(@now, @interval) == 0
      assert aging_entries(agent) == []
    end

    test "an open question ages the same way" do
      agent = uid("adrs")
      ask!(agent, 4 * 3_600 + 30)

      assert Aging.run(@now, @interval) == 1

      assert [entry] = aging_entries(agent)
      assert entry["event"] == "ask_aging"
      assert entry["summary"] =~ "a question has waited 4h"
      assert entry["summary"] =~ "is the diff yours?"
    end

    test "consecutive runs tile: a threshold is announced by exactly one of them" do
      agent = uid("once")
      gate!(agent, 3_600 + 60)

      assert Aging.run(@now, @interval) == 1
      assert Aging.run(DateTime.add(@now, @interval, :second), @interval) == 0
      assert Aging.run(DateTime.add(@now, 2 * @interval, :second), @interval) == 0

      assert [_only] = aging_entries(agent)
    end

    test "a pinned away still records it (ntfy rings); only the desktop is held" do
      agent = uid("away")
      gate!(agent, 3_600 + 60)
      Custode.Presence.set(:away)

      assert Aging.run(@now, @interval) == 1
      assert [_entry] = aging_entries(agent)
    end
  end

  describe "human/1" do
    test "says a threshold the way the operator would" do
      assert Aging.human(3_600) == "1h"
      assert Aging.human(14_400) == "4h"
      assert Aging.human(86_400) == "1d"
      assert Aging.human(172_800) == "2d"
      assert Aging.human(900) == "15m"
    end
  end

  describe "the job" do
    test "uses its own scheduled_at as the clock, so runs tile however late they start" do
      agent = uid("job")
      gate!(agent, 3_600 + 60)

      assert :ok = Custode.Aging.Job.perform(%Oban.Job{scheduled_at: @now})
      assert [_entry] = aging_entries(agent)
    end

    test "is on the crontab by default and off when disabled" do
      put_env!(:aging_cron, "*/10 * * * *")
      assert Enum.any?(Custode.Routine.crontab(), &match?({_cron, Custode.Aging.Job, _opts}, &1))

      put_env!(:aging_cron, false)
      refute Enum.any?(Custode.Routine.crontab(), &match?({_cron, Custode.Aging.Job, _opts}, &1))
    end
  end
end
