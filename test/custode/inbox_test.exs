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
end
