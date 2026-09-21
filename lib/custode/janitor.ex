defmodule Custode.Janitor do
  @moduledoc """
  Mechanical pruning (the deterministic half of #39): a daily sweep that
  deletes aged-out rows and files nothing will read again.

    * done todos and resolved/requeued/orphaned gates past retention
    * feed entries past retention (the db is authoritative since #44)
    * FILED inbox notes past retention (unfiled notes are never touched)
    * FINISHED workflow runs past retention, with their node results and the
      report artifacts those results point at

  Journals shrink only through the two-phase rule (#214): the agent
  distills entries into a summary (marking them `compacted_at`), and only
  THEN, once they also age out, does this sweep retire them. A journal
  entry the agent has not distilled is immortal here. Memories are never
  touched mechanically at all -- the agent's own `forget` is the only path.

  Retention is config (`config :custode, janitor: [...]`, days); a nil
  value disables that line. Every run that removes anything feeds a
  summary -- no silent truncation.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo
  alias Custode.Workflow.Results
  alias Custode.Workflow.Run

  @defaults [
    done_todos_days: 30,
    resolved_gates_days: 90,
    feed_days: 90,
    filed_notes_days: 30,
    ledger_detail_days: 90,
    uploads_days: 30,
    journal_compacted_days: 30,
    workflow_runs_days: 90
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    {runs, node_results, artifacts} = prune_workflow_runs()

    removed =
      [
        {"done todos", prune_todos()},
        {"resolved gates", prune_gates()},
        {"feed entries", prune_feed()},
        {"filed notes", prune_filed_notes()},
        {"idle sub-agents", reap_subagents()},
        {"ledger rows rolled up", rollup_ledger()},
        {"stale uploads", prune_uploads()},
        {"compacted journal entries", prune_compacted_journal()},
        {"retired workflow runs", runs},
        {"workflow node results", node_results},
        {"workflow report artifacts", artifacts}
      ]
      |> Enum.reject(fn {_what, count} -> count == 0 end)

    unless removed == [] do
      summary = Enum.map_join(removed, ", ", fn {what, count} -> "#{count} #{what}" end)
      Custode.Feed.record(%{event: "janitor", agent: "custode", summary: "pruned " <> summary})
    end

    :ok
  end

  defp prune_todos do
    delete(retention(:done_todos_days), fn cutoff ->
      from(t in Custode.Notebook.Todo, where: t.status == "done" and t.updated_at < ^cutoff)
    end)
  end

  defp prune_gates do
    delete(retention(:resolved_gates_days), fn cutoff ->
      from(g in Custode.Gates.Gate, where: g.status != "open" and g.updated_at < ^cutoff)
    end)
  end

  defp prune_feed do
    delete(retention(:feed_days), fn cutoff ->
      from(f in Custode.Feed.Entry, where: f.at < ^cutoff)
    end)
  end

  # The two-phase rule (#214): journals shrink ONLY through the agent's own
  # distillation. A journal entry is deleted here only if it is BOTH
  # compacted (the agent folded it into a summary) AND aged out -- the
  # summary carries its meaning forward, and the retention window keeps the
  # raw entry available on the dashboard until then. Live (never-distilled)
  # entries are immortal to this sweep by construction.
  defp prune_compacted_journal do
    delete(retention(:journal_compacted_days), fn cutoff ->
      from(e in Custode.Notebook.JournalEntry,
        where: not is_nil(e.compacted_at) and e.compacted_at < ^cutoff
      )
    end)
  end

  # #39/#271: `workflow_node_results` is the heavy table (one JSON result per
  # node of a many-node dig), and design/005 says the growth inventory must
  # cover it from day one. It prunes by RUN, not by row age, and only for a
  # run that has FINISHED: a `running` or `budget_paused` run's results are
  # what makes it resumable, so deleting them by age alone would silently
  # re-run nodes an operator already paid for. Same shape as the journal's
  # two-phase rule -- age is the second condition, never the only one.
  #
  # The run row goes with its results. A run row whose results have been
  # deleted renders as a stage checklist with nothing in it, which reads like
  # a run that did no work rather than one that aged out; retiring the pair
  # keeps the page honest.
  #
  # The report ARTIFACT a result points at goes too (design/005 names the
  # files alongside the table). It is read BEFORE the rows are deleted: after
  # that nothing in the fleet names the file, so a report left behind is
  # unreachable growth. The one condition is containment -- see
  # `artifact_removed?/2`.
  defp prune_workflow_runs do
    case retention(:workflow_runs_days) do
      nil ->
        {0, 0, 0}

      days ->
        cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

        finished =
          Repo.all(
            from(r in Run.Row,
              where:
                r.status in ["complete", "failed"] and not is_nil(r.finished_at) and
                  r.finished_at < ^cutoff,
              select: [:run_id, :context]
            )
          )

        artifacts = Enum.sum(Enum.map(finished, &prune_artifacts/1))
        run_ids = Enum.map(finished, & &1.run_id)
        results = Enum.sum(Enum.map(run_ids, &Results.delete_run/1))

        {count, _returning} =
          Repo.delete_all(from(r in Run.Row, where: r.run_id in ^run_ids))

        {count, results, artifacts}
    end
  end

  defp prune_artifacts(%Run.Row{run_id: run_id, context: context}) do
    case artifact_root(context) do
      nil ->
        0

      root ->
        run_id
        |> Results.artifacts()
        |> Enum.count(&artifact_removed?(root, &1))
    end
  end

  # The tree an artifact may be deleted from: the run's `artifact_dir` (where
  # custode writes reports since design/005 slice 5), else its `working_dir`
  # for a run recorded before that field existed. Same fallback
  # `Custode.Workflow.Report.dir/1` uses, so what writes the file and what
  # retires it agree about where it belongs.
  defp artifact_root(context) do
    with {:ok, decoded} <- Jason.decode(context || "{}"),
         dir when is_binary(dir) <-
           Map.get(decoded, "artifact_dir") || Map.get(decoded, "working_dir") do
      Path.expand(dir)
    else
      _no_root -> nil
    end
  end

  # An artifact path is stored data, and a stored path is only as trustworthy
  # as whatever put it there -- custode writes today's reports itself, but the
  # column has always been able to hold a claim a turn made. So it is resolved
  # against the run's artifact root and deleted only if it stays inside it:
  # `../../mix.exs`
  # and an absolute path elsewhere on the disk both resolve out of the run's
  # tree and are refused. Same doctrine as Custode.Uploads (#180) -- a path
  # that comes back from a turn buys no reach it did not already have.
  defp artifact_removed?(root, artifact) do
    path = Path.expand(artifact, root)

    if inside?(root, path) and File.regular?(path) do
      File.rm(path) == :ok
    else
      false
    end
  end

  defp inside?(root, path) do
    String.starts_with?(path, root <> "/")
  end

  defp delete(nil, _query_fun), do: 0

  defp delete(days, query_fun) do
    cutoff = DateTime.add(DateTime.utc_now(), -days, :day)
    {count, _returning} = Repo.delete_all(query_fun.(cutoff))
    count
  end

  defp prune_filed_notes do
    case retention(:filed_notes_days) do
      nil ->
        0

      days ->
        cutoff = Date.add(Date.utc_today(), -days)

        Custode.Routine.all()
        |> Enum.flat_map(&filed_notes_past(&1, cutoff))
        |> Enum.count(fn path ->
          File.rm(path) == :ok
        end)
    end
  end

  defp filed_notes_past(routine, cutoff) do
    inbox = routine.workspace |> Path.expand() |> Path.join("inbox")

    for path <- Path.wildcard(Path.join(inbox, "*")),
        File.regular?(path),
        date = filed_date(path),
        date != nil,
        Date.compare(date, cutoff) == :lt do
      path
    end
  end

  # a filed note starts "FILED YYYY-MM-DD"; anything else is untouchable
  defp filed_date(path) do
    with {:ok, content} <- File.read(path),
         "FILED " <> rest <- content,
         {:ok, date} <- rest |> String.slice(0, 10) |> Date.from_iso8601() do
      date
    else
      _not_filed -> nil
    end
  end

  # #39: ledger detail past retention compacts into one rollup row per
  # (agent, month, model, work provenance) stamped at the month's first instant, totals
  # preserved -- today/fleet_today are unaffected (they read the recent
  # window) and the metrics daily series degrades gracefully to
  # month-granularity for old data instead of losing the spend entirely.
  defp rollup_ledger do
    case retention(:ledger_detail_days) do
      nil ->
        0

      days ->
        cutoff = DateTime.add(DateTime.utc_now(), -days, :day)

        old =
          Repo.all(
            from(s in Custode.SpendLedger.Entry,
              where: s.inserted_at < ^cutoff and s.outcome != "rollup"
            )
          )

        old
        |> Enum.group_by(fn row ->
          {
            row.agent_id,
            row.inserted_at.year,
            row.inserted_at.month,
            row.model,
            row.attempt_id,
            row.work_item_id,
            row.mission_id,
            row.provider,
            row.legacy_routine_id
          }
        end)
        |> Enum.each(fn {
                          {agent_id, year, month, model, attempt_id, work_item_id, mission_id,
                           provider, legacy_routine_id},
                          rows
                        } ->
          {:ok, at} = DateTime.new(Date.new!(year, month, 1), ~T[00:00:00.000000], "Etc/UTC")

          Repo.insert!(%Custode.SpendLedger.Entry{
            agent_id: agent_id,
            cost_usd: rows |> Enum.map(& &1.cost_usd) |> Enum.sum() |> Kernel.*(1.0),
            outcome: "rollup",
            input_tokens: sum_field(rows, :input_tokens),
            output_tokens: sum_field(rows, :output_tokens),
            cache_creation_tokens: sum_field(rows, :cache_creation_tokens),
            cache_read_tokens: sum_field(rows, :cache_read_tokens),
            model: model,
            attempt_id: attempt_id,
            work_item_id: work_item_id,
            mission_id: mission_id,
            provider: provider,
            legacy_routine_id: legacy_routine_id,
            inserted_at: at
          })
        end)

        ids = Enum.map(old, & &1.id)
        {count, _} = Repo.delete_all(from(s in Custode.SpendLedger.Entry, where: s.id in ^ids))
        count
    end
  end

  defp sum_field(rows, field) do
    rows |> Enum.map(&Map.get(&1, field)) |> Enum.reject(&is_nil/1) |> Enum.sum()
  end

  # #39/#180: content-hashed screenshots under <workspace>/uploads age out
  # once their turn is long past; the prompt text carries the path, so a
  # very old feed entry may reference a pruned file -- retention matches
  # the feed's own story, not forever.
  defp prune_uploads do
    case retention(:uploads_days) do
      nil ->
        0

      days ->
        cutoff = System.os_time(:second) - days * 86_400

        Custode.Routine.all()
        |> Enum.flat_map(fn routine ->
          routine.workspace |> Path.expand() |> Path.join("uploads/*") |> Path.wildcard()
        end)
        |> Enum.count(&stale_upload_removed?(&1, cutoff))
    end
  end

  defp stale_upload_removed?(path, cutoff) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} when mtime < cutoff -> File.rm(path) == :ok
      _fresh_or_gone -> false
    end
  end

  # #16: an ephemeral sub-agent idle past the TTL (by its last feed
  # activity) is holding a session and a registry slot nobody will use;
  # stop it. Its journal/memory/ghost tile (#11) all persist. Gated,
  # waiting, running, and paused ephemerals are never touched.
  defp reap_subagents do
    case Keyword.get(janitor_config(), :subagent_ttl_s, 7_200) do
      nil ->
        0

      ttl ->
        routine_ids = Enum.map(Custode.Routine.all(), & &1.id)
        cutoff = DateTime.add(DateTime.utc_now(), -ttl)

        Custode.Agents.list()
        |> Enum.filter(fn {id, status} -> id not in routine_ids and status == :idle end)
        |> Enum.count(fn {id, _status} -> maybe_stop(id, cutoff) end)
    end
  end

  defp maybe_stop(id, cutoff) do
    with %DateTime{} = last <- Custode.Feed.last_activity_at(id),
         :lt <- DateTime.compare(last, cutoff) do
      :ok = Custode.Agents.stop_agent(id)
      true
    else
      _fresh_or_unknown -> false
    end
  end

  defp janitor_config, do: Application.get_env(:custode, :janitor, [])

  defp retention(key) do
    Keyword.get(janitor_config(), key, @defaults[key])
  end
end
