defmodule Custode.Janitor do
  @moduledoc """
  Mechanical pruning (the deterministic half of #39): a daily sweep that
  deletes aged-out rows and files nothing will read again.

    * done todos and resolved/requeued/orphaned gates past retention
    * feed entries past retention (the db is authoritative since #44)
    * FILED inbox notes past retention (unfiled notes are never touched)

  Journals and memories are deliberately NOT here: they are the agents'
  long-term selves and only shrink through semantic compaction (an agent
  distilling before anything is deleted) -- the other half of #39.

  Retention is config (`config :custode, janitor: [...]`, days); a nil
  value disables that line. Every run that removes anything feeds a
  summary -- no silent truncation.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @defaults [done_todos_days: 30, resolved_gates_days: 90, feed_days: 90, filed_notes_days: 30]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    removed =
      [
        {"done todos", prune_todos()},
        {"resolved gates", prune_gates()},
        {"feed entries", prune_feed()},
        {"filed notes", prune_filed_notes()}
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

  defp retention(key) do
    Application.get_env(:custode, :janitor, [])
    |> Keyword.get(key, @defaults[key])
  end
end
