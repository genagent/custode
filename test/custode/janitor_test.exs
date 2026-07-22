defmodule Custode.JanitorTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Janitor

  defp perform!, do: Janitor.perform(%Oban.Job{args: %{}})

  defp backdate!(table, id, column, days) do
    cutoff = DateTime.utc_now() |> DateTime.add(-days, :day) |> DateTime.to_iso8601()

    Custode.Repo.query!("UPDATE #{table} SET #{column} = ? WHERE id = ?", [cutoff, id])
  end

  test "prunes aged done todos, resolved gates, and feed entries; keeps the live ones" do
    routine = routine_fixture!(tmp_workspace!())

    {:ok, old_done} = Custode.Notebook.todo_add(routine.id, "ancient chore", source: "test")
    {:ok, _} = Custode.Notebook.todo_complete(old_done.id)
    backdate!("todos", old_done.id, "updated_at", 45)

    {:ok, fresh_done} = Custode.Notebook.todo_add(routine.id, "recent chore", source: "test")
    {:ok, _} = Custode.Notebook.todo_complete(fresh_done.id)

    {:ok, open} = Custode.Notebook.todo_add(routine.id, "still open", source: "test")
    backdate!("todos", open.id, "updated_at", 400)

    agent = uid("jan")
    Custode.Feed.record(%{event: "turn", agent: agent, summary: "ancient"})
    [%{"summary" => "ancient"}] = Custode.Feed.for_agent(agent)

    [[old_feed_id]] =
      Custode.Repo.query!("SELECT id FROM feed_entries ORDER BY id DESC LIMIT 1").rows

    backdate!("feed_entries", old_feed_id, "at", 120)
    Custode.Feed.record(%{event: "turn", agent: agent, summary: "fresh"})

    :ok = perform!()

    texts = Custode.Notebook.todos(routine.id, "all") |> Enum.map(& &1.text)
    assert "still open" in texts
    assert "recent chore" in texts
    refute "ancient chore" in texts

    assert ["fresh"] = Custode.Feed.for_agent(agent) |> Enum.map(& &1["summary"])
  end

  test "removes FILED notes past retention; never touches unfiled notes",
       %{} do
    workspace = tmp_workspace!()
    _routine = routine_fixture!(workspace)
    inbox = Path.join(workspace, "inbox")

    old_date = Date.utc_today() |> Date.add(-60) |> Date.to_iso8601()
    fresh_date = Date.utc_today() |> Date.to_iso8601()

    File.write!(Path.join(inbox, "old-filed.md"), "FILED #{old_date}\n\nold stuff\n")
    File.write!(Path.join(inbox, "fresh-filed.md"), "FILED #{fresh_date}\n\nnew stuff\n")
    File.write!(Path.join(inbox, "unfiled.md"), "never read yet\n")

    :ok = perform!()

    refute File.exists?(Path.join(inbox, "old-filed.md"))
    assert File.exists?(Path.join(inbox, "fresh-filed.md"))
    assert File.exists?(Path.join(inbox, "unfiled.md"))
  end

  test "nil retention disables a line" do
    put_env!(:janitor, done_todos_days: nil, filed_notes_days: nil)

    routine = routine_fixture!(tmp_workspace!())
    {:ok, todo} = Custode.Notebook.todo_add(routine.id, "immortal", source: "test")
    {:ok, _} = Custode.Notebook.todo_complete(todo.id)
    backdate!("todos", todo.id, "updated_at", 3650)

    :ok = perform!()

    assert Enum.any?(Custode.Notebook.todos(routine.id, "all"), &(&1.text == "immortal"))
  end

  test "old ledger detail rolls up into monthly rows; totals survive (#39)" do
    agent = uid("ledger")
    :ok = Custode.SpendLedger.record(agent, 1.25, "turn", usage: %{input: 100, output: 50})
    :ok = Custode.SpendLedger.record(agent, 0.75, "turn", usage: %{input: 60, output: 30})
    :ok = Custode.SpendLedger.record(agent, 0.10)

    [[id1], [id2]] =
      Custode.Repo.query!(
        "SELECT id FROM spend WHERE agent_id = ? ORDER BY id LIMIT 2",
        [agent]
      ).rows

    backdate!("spend", id1, "inserted_at", 120)
    backdate!("spend", id2, "inserted_at", 120)

    :ok = perform!()

    rows =
      Custode.Repo.query!(
        "SELECT outcome, cost_usd, input_tokens FROM spend WHERE agent_id = ? ORDER BY id",
        [agent]
      ).rows

    # two old rows became one rollup; the fresh row is untouched detail
    assert [["turn", 0.1, nil], ["rollup", rolled, 160]] = rows
    assert_in_delta rolled, 2.0, 0.001

    # and the all-time total is preserved through the compaction
    total = Custode.SpendLedger.total(agent, DateTime.add(DateTime.utc_now(), -365, :day))
    assert_in_delta total, 2.1, 0.001
  end

  test "stale uploads age out; fresh ones stay (#39/#180)" do
    routine = routine_fixture!(tmp_workspace!())
    uploads = routine.workspace |> Path.expand() |> Path.join("uploads")
    File.mkdir_p!(uploads)

    old = Path.join(uploads, "old.png")
    fresh = Path.join(uploads, "fresh.png")
    File.write!(old, "x")
    File.write!(fresh, "x")
    stale_mtime = System.os_time(:second) - 60 * 86_400
    File.touch!(old, stale_mtime)

    :ok = perform!()

    refute File.exists?(old)
    assert File.exists?(fresh)
  end

  test "the janitor rides the crontab" do
    assert Enum.any?(Custode.Routine.crontab(), fn {cron, worker, _opts} ->
             cron == "@daily" and worker == Custode.Janitor
           end)
  end
end
