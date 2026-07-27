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

  test "compacted journal entries retire only once aged out; live entries are immortal (#214)" do
    routine = routine_fixture!(tmp_workspace!())

    # a live entry, an old-compacted entry, and a recently-compacted entry
    {:ok, live} = Custode.Notebook.journal_append(routine.id, "still true")
    {:ok, old} = Custode.Notebook.journal_append(routine.id, "long since folded in")
    {:ok, fresh} = Custode.Notebook.journal_append(routine.id, "just distilled")

    now = DateTime.utc_now() |> DateTime.to_iso8601()
    stale = DateTime.utc_now() |> DateTime.add(-120, :day) |> DateTime.to_iso8601()

    Custode.Repo.query!("UPDATE journal_entries SET compacted_at = ? WHERE id = ?", [
      stale,
      old.id
    ])

    Custode.Repo.query!("UPDATE journal_entries SET compacted_at = ? WHERE id = ?", [
      now,
      fresh.id
    ])

    # even a very old LIVE entry must survive: age alone never deletes it
    backdate!("journal_entries", live.id, "inserted_at", 400)

    :ok = perform!()

    bodies = Custode.Notebook.journal(routine.id, 50) |> Enum.map(& &1.body)
    assert "still true" in bodies
    assert "just distilled" in bodies
    refute "long since folded in" in bodies
  end

  test "finished workflow runs retire with their results; unfinished ones are immortal (#39/#271)" do
    alias Custode.Workflow.Results
    alias Custode.Workflow.Run

    old = uid("run")
    fresh = uid("run")
    paused = uid("run")

    for run_id <- [old, fresh, paused] do
      Run.start(run_id, "backlog-sweep", "genagent/custode", "mine")

      Results.put(%{
        workflow_run: run_id,
        workflow: "backlog-sweep",
        stage: "mine",
        node_name: "mine-spec",
        args_hash: Results.args_hash(%{topic: run_id}),
        result: %{"findings" => []}
      })
    end

    Run.complete(old)
    Run.complete(fresh)
    Run.budget_pause(paused, "rail hit", ["verify"])

    # the paused run is older than any retention window and still survives:
    # its results are what a resume reads instead of re-running the nodes
    for run_id <- [old, paused] do
      [[id]] = Custode.Repo.query!("SELECT id FROM workflow_runs WHERE run_id = ?", [run_id]).rows
      backdate!("workflow_runs", id, "started_at", 400)
      backdate!("workflow_runs", id, "finished_at", 400)
    end

    :ok = perform!()

    assert Run.get(old) == nil
    assert Results.for_run(old) == []

    assert Run.get(fresh).status == "complete"
    assert [_kept] = Results.for_run(fresh)

    assert Run.get(paused).status == "budget_paused"
    assert [_immortal] = Results.for_run(paused)
  end

  test "a retired run takes its report artifacts with it; a path outside the run stays (#39)" do
    alias Custode.Workflow.Results
    alias Custode.Workflow.Run

    root = tmp_workspace!()

    # a sibling of the run's tree, reachable from it by one `..`
    outside = Path.join(Path.dirname(root), uid("custode-outside") <> ".md")
    File.write!(outside, "not the run's to delete")
    on_exit(fn -> File.rm_rf!(outside) end)

    report = Path.join(root, "reports/dig.md")
    File.mkdir_p!(Path.dirname(report))
    File.write!(report, "# findings")

    old = uid("run")
    fresh = uid("run")

    for {run_id, artifact} <- [{old, "reports/dig.md"}, {fresh, "reports/kept.md"}] do
      Run.start(run_id, "backlog-sweep", "genagent/custode", "mine", %{"working_dir" => root})

      Results.put(%{
        workflow_run: run_id,
        workflow: "backlog-sweep",
        stage: "mine",
        node_name: "mine-spec",
        args_hash: Results.args_hash(%{topic: run_id}),
        result: %{"findings" => []},
        artifact: artifact
      })
    end

    # two more results on the retiring run, both naming the same file outside
    # the run's tree: once absolutely, once by climbing out with `..`
    for {node, artifact} <- [
          {"escapes-abs", outside},
          {"escapes-rel", Path.join("..", Path.basename(outside))}
        ] do
      Results.put(%{
        workflow_run: old,
        workflow: "backlog-sweep",
        stage: "mine",
        node_name: node,
        args_hash: Results.args_hash(%{topic: node}),
        result: %{},
        artifact: artifact
      })
    end

    Run.complete(old)
    [[id]] = Custode.Repo.query!("SELECT id FROM workflow_runs WHERE run_id = ?", [old]).rows
    backdate!("workflow_runs", id, "started_at", 400)
    backdate!("workflow_runs", id, "finished_at", 400)

    :ok = perform!()

    assert Run.get(old) == nil
    refute File.exists?(report)

    # containment: neither spelling of the escape is the janitor's to remove
    assert File.exists?(outside)

    # a live run's artifact is untouched, artifact or not
    assert Run.get(fresh).status == "running"
    assert [%{artifact: "reports/kept.md"}] = Results.for_run(fresh)
  end

  test "a run's report is retired from its artifact dir, not from its checkout (#275)" do
    alias Custode.Workflow.Results
    alias Custode.Workflow.Run

    artifact_dir = tmp_workspace!()
    checkout = tmp_workspace!()

    # the file custode wrote for this run, and a file in the repo the run was
    # reading -- same run, and only one of them is the janitor's to remove
    report = Path.join(artifact_dir, "report.md")
    File.write!(report, "# report")

    in_checkout = Path.join(checkout, "mix.exs")
    File.write!(in_checkout, "not the janitor's")

    run_id = uid("run")

    Run.start(run_id, "deep-report", "genagent/custode", "synthesis", %{
      "working_dir" => checkout,
      "artifact_dir" => artifact_dir
    })

    for {node, artifact} <- [{"report", report}, {"stray", in_checkout}] do
      Results.put(%{
        workflow_run: run_id,
        workflow: "deep-report",
        stage: "synthesis",
        node_name: node,
        args_hash: Results.args_hash(%{node: node}),
        result: %{},
        artifact: artifact
      })
    end

    Run.complete(run_id)
    [[id]] = Custode.Repo.query!("SELECT id FROM workflow_runs WHERE run_id = ?", [run_id]).rows
    backdate!("workflow_runs", id, "started_at", 400)
    backdate!("workflow_runs", id, "finished_at", 400)

    :ok = perform!()

    assert Run.get(run_id) == nil
    refute File.exists?(report)
    assert File.exists?(in_checkout)
  end

  test "the janitor rides the crontab" do
    assert Enum.any?(Custode.Routine.crontab(), fn {cron, worker, _opts} ->
             cron == "@daily" and worker == Custode.Janitor
           end)
  end
end
