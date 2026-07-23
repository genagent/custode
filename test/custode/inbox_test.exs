defmodule Custode.InboxTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Inbox

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{workspace: workspace, routine: routine}
  end

  defp beats_for(routine_id) do
    jobs_for("ObanClaude.Agent.Tick") |> Enum.filter(&(&1.args["agent_id"] == routine_id))
  end

  test "drop writes the note and schedules ONE debounced beat for a burst",
       %{workspace: workspace, routine: routine} do
    {:ok, path} = Inbox.drop(routine.id, "a.md", "note a\n")
    assert File.read!(path) == "note a\n"
    assert Path.dirname(path) == Path.join(workspace, "inbox")

    {:ok, _path} = Inbox.drop(routine.id, "b.md", "note b\n")
    {:ok, _path} = Inbox.drop(routine.id, "c.md", "note c\n")

    # three drops, one scheduled beat (Oban uniqueness on the agent id)
    assert [beat] = beats_for(routine.id)
    assert beat.state == "scheduled"
    assert beat.args["if_offline"] == "start"
  end

  test "on_note: :ignore drops the note without a beat", %{workspace: workspace} do
    quiet = routine_fixture!(workspace, %{on_note: :ignore})
    {:ok, _path} = Inbox.drop(quiet.id, "a.md", "quiet\n")
    assert beats_for(quiet.id) == []
  end

  test "unknown routines are refused" do
    assert {:error, :unknown_routine} = Inbox.drop("ghost", "a.md", "x")
  end

  test "drop_path fires the kickoff when the directory belongs to a routine",
       %{workspace: workspace, routine: routine} do
    inbox = Path.join(workspace, "inbox")
    {:ok, path} = Inbox.drop_path(inbox, "job-9-report.md", "report\n")
    assert File.exists?(path)
    assert [_beat] = beats_for(routine.id)

    # a foreign directory still gets the file, no beat anywhere
    outside = Path.join(System.tmp_dir!(), uid("elsewhere"))
    on_exit(fn -> File.rm_rf!(outside) end)
    {:ok, _path} = Inbox.drop_path(outside, "x.md", "y")
  end

  describe "the inbox_note feed entry (#261)" do
    test "drop records one entry per note, attributed to the routine",
         %{routine: routine} do
      {:ok, _path} = Inbox.drop(routine.id, "a.md", "note a\n")
      {:ok, _path} = Inbox.drop(routine.id, "b.md", "note b\n")

      entries = Custode.Feed.recent_by_event("inbox_note", agent: routine.id)

      assert [%{"note" => "b.md"}, %{"note" => "a.md"}] = entries
      assert Enum.all?(entries, &(&1["agent"] == routine.id))
      assert hd(entries)["summary"] =~ "#{routine.id}'s inbox: b.md"
    end

    test "a refused drop records nothing" do
      before = length(Custode.Feed.recent_by_event("inbox_note", limit: 100))
      assert {:error, :unknown_routine} = Inbox.drop("ghost", "a.md", "x")
      assert length(Custode.Feed.recent_by_event("inbox_note", limit: 100)) == before
    end

    test "drop_path attributes an owned directory to its routine",
         %{workspace: workspace, routine: routine} do
      inbox = Path.join(workspace, "inbox")
      {:ok, _path} = Inbox.drop_path(inbox, "job-9-report.md", "report\n")

      assert [%{"note" => "job-9-report.md"} | _rest] =
               Custode.Feed.recent_by_event("inbox_note", agent: routine.id)
    end

    test "drop_path attributes an unowned directory to the fleet, naming the directory" do
      outside = Path.join(System.tmp_dir!(), uid("elsewhere"))
      on_exit(fn -> File.rm_rf!(outside) end)
      name = uid("report") <> ".md"

      {:ok, _path} = Inbox.drop_path(outside, name, "y")

      entry =
        "inbox_note"
        |> Custode.Feed.recent_by_event(limit: 100)
        |> Enum.find(&(&1["note"] == name))

      assert entry["agent"] == "custode"
      assert entry["summary"] =~ outside
    end
  end
end
