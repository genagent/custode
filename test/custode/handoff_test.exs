defmodule Custode.HandoffTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{Handoff, Memory, Notebook}

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine, workspace: workspace}
  end

  test "renders the portable notebook state and its plan pointer", %{
    routine: routine,
    workspace: workspace
  } do
    {:ok, _} =
      Notebook.journal_append(routine.id, "chose the smaller migration", title: "decision")

    {:ok, todo} = Notebook.todo_add(routine.id, "verify the client contract")
    :ok = Memory.remember(routine.id, "panel", "## Status\n\nTransport migration in progress.")

    path = Handoff.render!(routine)

    assert path == Path.join(Path.expand(workspace), "HANDOFF.md")
    assert content = File.read!(path)
    assert content =~ "# Context handoff: #{routine.id}"
    assert content =~ "chose the smaller migration"
    assert content =~ "(##{todo.id}) verify the client contract"
    assert content =~ "Transport migration in progress"
    assert content =~ Path.join(Path.expand(workspace), "TODO.md")
  end

  test "condenses the oldest journal material before the newest is removed", %{routine: routine} do
    {:ok, _} = Notebook.journal_append(routine.id, "oldest head\n" <> String.duplicate("a", 700))
    {:ok, _} = Notebook.journal_append(routine.id, "middle head\n" <> String.duplicate("b", 700))
    {:ok, _} = Notebook.journal_append(routine.id, "newest head\n" <> String.duplicate("c", 700))

    rendered = Handoff.render(routine, max_bytes: 1_800)

    assert byte_size(rendered) <= 1_800
    assert rendered =~ "oldest head"
    refute rendered =~ String.duplicate("a", 300)
    assert rendered =~ String.duplicate("c", 300)
  end
end
