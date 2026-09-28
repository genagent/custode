defmodule Custode.TicksTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.Ticks

  @now ~U[2026-09-19 12:00:00.000000Z]

  # oban_jobs is shared across the suite, so every job carries a marker and
  # every assertion is scoped to it.
  defp job!(marker, opts) do
    queue = Keyword.get(opts, :queue, "ticks")
    state = Keyword.get(opts, :state, "available")
    worker = Keyword.get(opts, :worker, "Custode.RoutineTick")
    due = DateTime.add(@now, -Keyword.fetch!(opts, :due_ago), :second)

    %{"routine_id" => marker}
    |> Custode.RoutineTick.new(queue: queue)
    |> Ecto.Changeset.change(
      state: state,
      worker: worker,
      scheduled_at: due,
      inserted_at: due
    )
    |> Repo.insert!()
  end

  defp state_of(job), do: Repo.one!(from(j in Oban.Job, where: j.id == ^job.id, select: j.state))

  describe "stale?/2" do
    test "a job due longer ago than the window is stale" do
      job = %Oban.Job{scheduled_at: DateTime.add(@now, -601, :second)}
      assert Ticks.stale?(job, @now)
    end

    test "a job that waited a few seconds for the slot is not" do
      job = %Oban.Job{scheduled_at: DateTime.add(@now, -30, :second)}
      refute Ticks.stale?(job, @now)
    end

    test "a job with no timestamp is a direct call, and a direct call is now" do
      refute Ticks.stale?(%Oban.Job{}, @now)
    end

    test "falls back to inserted_at when scheduled_at is absent" do
      job = %Oban.Job{inserted_at: DateTime.add(@now, -3_600, :second)}
      assert Ticks.stale?(job, @now)
    end

    test "the window is configurable" do
      put_env!(:stale_tick_seconds, 10)
      job = %Oban.Job{scheduled_at: DateTime.add(@now, -30, :second)}
      assert Ticks.stale?(job, @now)
    end
  end

  describe "discard_stale/1" do
    test "cancels the backlog a withheld queue accumulated, and only that" do
      marker = uid("stale")

      days_old = job!(marker, due_ago: 3 * 86_400)
      debounced = job!(marker, due_ago: 3_600, state: "scheduled")
      fresh = job!(marker, due_ago: 20)
      other_queue = job!(marker, due_ago: 3 * 86_400, queue: "sensors")
      already_done = job!(marker, due_ago: 3 * 86_400, state: "completed")

      durable_wake =
        job!(marker,
          due_ago: 3 * 86_400,
          state: "scheduled",
          worker: "Custode.InboxWakeJob"
        )

      assert Ticks.discard_stale(@now) >= 2

      assert state_of(days_old) == "cancelled"
      assert state_of(debounced) == "cancelled"
      assert state_of(fresh) == "available"
      assert state_of(other_queue) == "available"
      assert state_of(already_done) == "completed"
      assert state_of(durable_wake) == "scheduled"
    end

    test "is a no-op on a clean queue" do
      marker = uid("clean")
      fresh = job!(marker, due_ago: 5)

      Ticks.discard_stale(@now)

      assert state_of(fresh) == "available"
    end
  end
end
