defmodule Custode.InboxTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Inbox, InboxWakes}

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{workspace: workspace, routine: routine}
  end

  defp wake_jobs_for(routine_id) do
    jobs_for("Custode.InboxWakeJob")
    |> Enum.filter(
      &(&1.args["routine_id"] == routine_id and
          &1.state in ~w(available scheduled retryable executing))
    )
  end

  test "drop writes the note and retains one debounced wake for a burst",
       %{workspace: workspace, routine: routine} do
    {:ok, path} = Inbox.drop(routine.id, "a.md", "note a\n")
    assert File.read!(path) == "note a\n"
    assert Path.dirname(path) == Path.join(workspace, "inbox")

    {:ok, _path} = Inbox.drop(routine.id, "b.md", "note b\n")
    {:ok, _path} = Inbox.drop(routine.id, "c.md", "note c\n")

    assert %{
             wake_id: wake_id,
             reason: "inbox_activity",
             state: "pending",
             note_count: 3,
             blocked_by: "debounce"
           } = InboxWakes.get(routine.id)

    assert [job] = wake_jobs_for(routine.id)
    assert job.queue == "ticks"
    assert job.args == %{"routine_id" => routine.id, "wake_id" => wake_id}
  end

  test "on_note: :ignore drops the note without a wake", %{workspace: workspace} do
    quiet = routine_fixture!(workspace, %{on_note: :ignore})
    {:ok, _path} = Inbox.drop(quiet.id, "a.md", "quiet\n")
    assert InboxWakes.get(quiet.id) == nil
    assert wake_jobs_for(quiet.id) == []
  end

  test "unknown routines are refused" do
    assert {:error, :unknown_routine} = Inbox.drop("ghost", "a.md", "x")
  end

  test "drop_path fires the kickoff when the directory belongs to a routine",
       %{workspace: workspace, routine: routine} do
    inbox = Path.join(workspace, "inbox")
    {:ok, path} = Inbox.drop_path(inbox, "job-9-report.md", "report\n")
    assert File.exists?(path)
    assert %{wake_id: wake_id, note_count: 1} = InboxWakes.get(routine.id)
    assert [%{args: %{"wake_id" => ^wake_id}}] = wake_jobs_for(routine.id)

    # A foreign directory still gets the file and does not add a wake.
    outside = Path.join(System.tmp_dir!(), uid("elsewhere"))
    on_exit(fn -> File.rm_rf!(outside) end)
    {:ok, _path} = Inbox.drop_path(outside, "x.md", "y")
    assert [%{args: %{"wake_id" => ^wake_id}}] = wake_jobs_for(routine.id)
  end

  test "general notes cannot overwrite peer receipts or use paths", %{
    routine: routine,
    workspace: workspace
  } do
    name = "peer-#{Ecto.UUID.generate()}.md"
    inbox = Path.join(workspace, "inbox")
    path = Path.join(inbox, name)
    File.write!(path, "original peer content")

    for drop <- [
          fn note -> Inbox.drop(routine, note, "FILED forged") end,
          fn note -> Inbox.drop_path(inbox, note, "FILED forged") end
        ] do
      assert {:error, :reserved_peer_note} = drop.(name)
      assert {:error, :invalid_note_name} = drop.("../inbox/" <> name)
      assert {:error, :invalid_note_name} = drop.(path)
    end

    assert File.read!(path) == "original peer content"
    assert InboxWakes.get(routine.id) == nil
    assert Custode.Feed.recent_by_event("inbox_note", agent: routine.id) == []
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
