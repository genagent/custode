defmodule Custode.NextBeatTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.MCP.NotebookTools.SetNextBeat
  alias Custode.NextBeat
  alias Custode.Scheduler

  @now ~U[2026-09-21 10:00:00Z]

  defp routine(id, cron), do: %{id: id, cron: cron}

  defp frame_for(id),
    do: %Custode.MCP.CallContext{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  describe "request/3" do
    test "records the wait, and a second request replaces the first" do
      id = uid("waiter")

      assert {:ok, %{minutes: 40, clamped?: false, at: at}} =
               NextBeat.request(id, 40, now: @now, reason: "CI takes 40m")

      assert DateTime.compare(at, ~U[2026-09-21 10:40:00Z]) == :eq
      assert %{reason: "CI takes 40m", requested_minutes: 40} = NextBeat.get(id)

      {:ok, %{at: later}} = NextBeat.request(id, 90, now: @now)
      assert NextBeat.pending()[id] == later
    end

    test "the wait is clamped to the operator's bounds, and says so" do
      put_env!(:next_beat_bounds, {10, 120})
      id = uid("waiter")

      # an agent cannot use this to run MORE often than the floor
      assert {:ok, %{minutes: 10, clamped?: true}} = NextBeat.request(id, 1, now: @now)
      assert {:ok, %{minutes: 120, clamped?: true}} = NextBeat.request(id, 100_000, now: @now)
      assert {:ok, %{minutes: 10, clamped?: true}} = NextBeat.request(id, -5, now: @now)
    end
  end

  describe "Scheduler.due/4 with a request" do
    test "until its time the cron's beats are skipped; at its time it fires once, cron or not" do
      every_minute = routine("eager", "* * * * *")
      requested = %{"eager" => ~U[2026-09-21 10:40:00Z]}

      assert {[], _seen} = Scheduler.due([every_minute], ~U[2026-09-21 10:05:00Z], %{}, requested)
      assert {[], _seen} = Scheduler.due([every_minute], ~U[2026-09-21 10:39:30Z], %{}, requested)

      # a cron that does NOT match this minute still fires when the request is due
      daily = routine("eager", "0 3 * * *")
      assert {["eager"], seen} = Scheduler.due([daily], ~U[2026-09-21 10:40:10Z], %{}, requested)
      # and not twice in the same minute
      assert {[], _seen} = Scheduler.due([daily], ~U[2026-09-21 10:40:50Z], seen, requested)
    end

    test "a routine with no request is scheduled exactly as before" do
      assert {["a"], _seen} =
               Scheduler.due([routine("a", "* * * * *")], @now, %{}, %{"b" => @now})
    end

    test "the request is spent the moment the scheduler fires it" do
      id = uid("spent")

      put_env!(:routines, [%{id: id, cron: "0 3 * * *", workspace: tmp_workspace!(), prompt: "x"}])

      {:ok, _granted} = NextBeat.request(id, 5, now: DateTime.add(DateTime.utc_now(), -600))

      test_pid = self()

      {:ok, pid} =
        Scheduler.start_link(
          name: nil,
          autostart: false,
          insert_job: fn changeset ->
            args = Ecto.Changeset.get_field(changeset, :args)
            send(test_pid, {:fired, args["routine_id"]})
            {:ok, %Oban.Job{args: args}}
          end
        )

      assert id in Scheduler.tick(pid)
      assert_received {:fired, ^id}
      assert NextBeat.get(id) == nil
    end
  end

  describe "anything else that starts a turn clears it" do
    test "a transition to :running forgets the request" do
      id = uid("woken")
      {:ok, _granted} = NextBeat.request(id, 60)

      :ok =
        NextBeat.handle_event(
          [:oban_claude, :agent, :transition],
          %{},
          %{agent_id: id, from: :idle, to: :running},
          nil
        )

      assert NextBeat.get(id) == nil
    end

    test "a Codex transition to :running also forgets the request" do
      id = uid("codex-woken")
      {:ok, _granted} = NextBeat.request(id, 60)

      :ok =
        NextBeat.handle_event(
          [:oban_codex, :agent, :transition],
          %{},
          %{agent_id: id, from: :idle, to: :running},
          nil
        )

      assert NextBeat.get(id) == nil
    end

    test "other transitions leave it alone" do
      id = uid("resting")
      {:ok, _granted} = NextBeat.request(id, 60)

      :ok =
        NextBeat.handle_event(
          [:oban_claude, :agent, :transition],
          %{},
          %{agent_id: id, from: :running, to: :idle},
          nil
        )

      assert %NextBeat{} = NextBeat.get(id)
    end
  end

  describe "the set_next_beat tool" do
    setup do
      path = Path.join(System.tmp_dir!(), uid("next-beat") <> ".jsonl")
      put_env!(:feed_path, path)
      on_exit(fn -> File.rm(path) end)
      :ok
    end

    test "an agent sets its own, is told what it got, and the feed says why" do
      id = uid("asker")

      json =
        tool_json(SetNextBeat.execute(%{minutes: 40, reason: "CI takes 40m"}, frame_for(id)))

      assert %{"minutes" => 40, "clamped" => false, "next_beat_at" => _at} = json
      assert %NextBeat{requested_minutes: 40} = NextBeat.get(id)

      assert [%{"summary" => "next beat in 40m: CI takes 40m"}] =
               Custode.Feed.recent_by_event("next_beat", agent: id)
    end

    test "it is self-scoped, and names a missing field" do
      id = uid("asker")
      other = uid("other")

      assert tool_error(
               SetNextBeat.execute(
                 %{routine_id: other, minutes: 40, reason: "not mine"},
                 frame_for(id)
               )
             ) =~ "may not write"

      assert NextBeat.get(other) == nil
      assert tool_error(SetNextBeat.execute(%{minutes: 40}, frame_for(id))) =~ "reason"
    end
  end
end
