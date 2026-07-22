defmodule Custode.Janitor do
  @moduledoc """
  Mechanical pruning (the deterministic half of #39): a daily sweep that
  deletes aged-out rows and files nothing will read again.

    * done todos and resolved/requeued/orphaned gates past retention
    * feed entries past retention (the db is authoritative since #44)
    * FILED inbox notes past retention (unfiled notes are never touched)

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

  @defaults [
    done_todos_days: 30,
    resolved_gates_days: 90,
    feed_days: 90,
    filed_notes_days: 30,
    ledger_detail_days: 90,
    uploads_days: 30,
    journal_compacted_days: 30
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    removed =
      [
        {"done todos", prune_todos()},
        {"resolved gates", prune_gates()},
        {"feed entries", prune_feed()},
        {"filed notes", prune_filed_notes()},
        {"idle sub-agents", reap_subagents()},
        {"ledger rows rolled up", rollup_ledger()},
        {"stale uploads", prune_uploads()},
        {"compacted journal entries", prune_compacted_journal()}
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
  # (agent, month, model) stamped at the month's first instant, totals
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
          {row.agent_id, row.inserted_at.year, row.inserted_at.month, row.model}
        end)
        |> Enum.each(fn {{agent_id, year, month, model}, rows} ->
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

        ObanClaude.Agent.list()
        |> Enum.filter(fn {id, status} -> id not in routine_ids and status == :idle end)
        |> Enum.count(fn {id, _status} -> maybe_stop(id, cutoff) end)
    end
  end

  defp maybe_stop(id, cutoff) do
    with %DateTime{} = last <- Custode.Feed.last_activity_at(id),
         :lt <- DateTime.compare(last, cutoff) do
      :ok = ObanClaude.Agent.stop_agent(id)
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
