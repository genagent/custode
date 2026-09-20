defmodule Custode.RuntimeWorkspaceTest do
  # #496: the operator added `mcp-repl` from the dashboard on the live fleet
  # and its first sweep reported that the journal append failed
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ExUnit.CaptureLog

  alias Custode.Config.WriteBack
  alias Custode.Notebook

  setup do
    roster = Path.join(System.tmp_dir!(), uid("runtime-roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", roster)
    previous = Application.get_env(:custode, :routines)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(roster)
      Application.put_env(:custode, :routines, previous)
    end)

    %{base: tmp_workspace!()}
  end

  test "a routine added at runtime has its workspace and inbox at once", %{base: base} do
    id = uid("newcomer")
    workspace = Path.join(base, "not-created-yet")
    refute File.exists?(workspace)

    {:ok, _path} =
      WriteBack.add_routine(%{id: id, cron: "@daily", workspace: workspace, prompt: "sweep"})

    assert File.dir?(Path.join(workspace, "inbox"))
  end

  test "and its first journal entry is written and rendered, not an internal error",
       %{base: base} do
    id = uid("newcomer")
    workspace = Path.join(base, "fresh")

    {:ok, _path} =
      WriteBack.add_routine(%{id: id, cron: "@daily", workspace: workspace, prompt: "sweep"})

    assert {:ok, entry} = Notebook.journal_append(id, "nothing workable", title: "Sweep")
    assert entry.id
    assert File.read!(Path.join(workspace, "journal.md")) =~ "nothing workable"
  end

  test "a workspace deleted out from under a routine is recreated by the next write",
       %{base: base} do
    routine = routine_fixture!(Path.join(base, "will-vanish"))
    Custode.Routine.ensure_workspace!(routine)
    File.rm_rf!(routine.workspace)

    assert {:ok, _entry} = Notebook.journal_append(routine.id, "still here")
    assert File.read!(Path.join(routine.workspace, "journal.md")) =~ "still here"
  end

  # the views are regenerable and the row is already committed (design/002)
  test "a view that cannot be written does not turn a committed write into an error",
       %{base: base} do
    # a FILE where the workspace directory should be: mkdir_p cannot succeed
    blocker = Path.join(base, "blocked")
    File.write!(blocker, "not a directory")
    routine = routine_fixture!(blocker)

    log =
      capture_log(fn ->
        assert {:ok, entry} = Notebook.journal_append(routine.id, "committed anyway")
        assert entry.id
      end)

    assert log =~ "notebook views for #{routine.id} not rendered"
    assert [%{body: "committed anyway"} | _rest] = Notebook.journal(routine.id, 5)
  end
end
