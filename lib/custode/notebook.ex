defmodule Custode.Notebook do
  @moduledoc """
  The mechanical memory: database-backed journal entries and todos, mutated
  through this context (and the MCP tools that wrap it) instead of free-form
  markdown edits. The workspace's `journal.md` / `TODO.md` become *generated
  views*, re-rendered after every mutation -- the git-diffable paper trail
  survives, but the source of truth is queryable, transactional, and safe
  under concurrent writers.

  Every mutation broadcasts `{:notebook_changed, routine_id}` on the agents
  topic, so the dashboard re-reads without polling.

  The inbox stays file-based on purpose (drop-a-file-to-poke and the one-shot
  `report_inbox` channel are load-bearing as plain files); this module makes
  the FILED bookkeeping mechanical via `unfiled_notes/1` / `mark_filed!/2`.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule JournalEntry do
    @moduledoc false
    use Ecto.Schema

    schema "journal_entries" do
      field(:routine_id, :string)
      field(:title, :string)
      field(:body, :string)
      field(:source, :string, default: "sweep")
      timestamps(type: :utc_datetime_usec)
    end
  end

  defmodule Todo do
    @moduledoc false
    use Ecto.Schema

    schema "todos" do
      field(:routine_id, :string)
      field(:text, :string)
      field(:status, :string, default: "open")
      field(:source, :string, default: "sweep")
      timestamps(type: :utc_datetime_usec)
    end
  end

  # ---------------------------------------------------------------------------
  # journal
  # ---------------------------------------------------------------------------

  @doc "Append a journal entry, re-render the markdown view, notify."
  def journal_append(routine_id, body, opts \\ []) when is_binary(body) do
    entry =
      Repo.insert!(%JournalEntry{
        routine_id: routine_id,
        title: opts[:title],
        body: body,
        source: opts[:source] || "sweep"
      })

    after_mutation(routine_id)
    {:ok, entry}
  end

  @doc "The newest `n` journal entries, newest first."
  def journal(routine_id, n \\ 20) do
    Repo.all(
      from(e in JournalEntry,
        where: e.routine_id == ^routine_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^n
      )
    )
  end

  # ---------------------------------------------------------------------------
  # todos
  # ---------------------------------------------------------------------------

  @doc "Add an open todo, re-render, notify."
  def todo_add(routine_id, text, opts \\ []) when is_binary(text) do
    todo =
      Repo.insert!(%Todo{routine_id: routine_id, text: text, source: opts[:source] || "sweep"})

    after_mutation(routine_id)
    {:ok, todo}
  end

  @doc "Todos for a routine: status \"open\" (default), \"done\", or \"all\"."
  def todos(routine_id, status \\ "open") do
    base = from(t in Todo, where: t.routine_id == ^routine_id, order_by: [asc: t.id])

    query = if status == "all", do: base, else: from(t in base, where: t.status == ^status)
    Repo.all(query)
  end

  @doc "Mark a todo done by id, re-render, notify."
  def todo_complete(id) do
    case Repo.get(Todo, id) do
      nil ->
        {:error, :not_found}

      todo ->
        todo = todo |> Ecto.Changeset.change(status: "done") |> Repo.update!()
        after_mutation(todo.routine_id)
        {:ok, todo}
    end
  end

  # ---------------------------------------------------------------------------
  # inbox (file-based, bookkeeping made mechanical)
  # ---------------------------------------------------------------------------

  @doc "Unfiled inbox notes for a routine: `[%{name: ..., content: ...}]`."
  def unfiled_notes(routine) do
    routine.workspace
    |> Path.expand()
    |> Path.join("inbox/*.md")
    |> Path.wildcard()
    |> Enum.map(&%{name: Path.basename(&1), content: File.read!(&1)})
    |> Enum.reject(&String.starts_with?(&1.content, "FILED"))
  end

  @doc "Prepend the FILED marker to an inbox note (idempotent; name only, no paths)."
  def mark_filed!(routine, name) do
    if Path.basename(name) != name, do: raise(ArgumentError, "note name must not be a path")

    path = routine.workspace |> Path.expand() |> Path.join("inbox") |> Path.join(name)
    content = File.read!(path)

    unless String.starts_with?(content, "FILED") do
      stamp = Date.utc_today() |> Date.to_iso8601()
      File.write!(path, "FILED #{stamp}\n\n" <> content)
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # rendered views
  # ---------------------------------------------------------------------------

  @doc "Re-render `journal.md` and `TODO.md` in the routine's workspace."
  def render!(routine_id) do
    case Custode.Routine.get(routine_id) do
      # not a configured routine (e.g. a sub-agent journaling): nothing to render
      nil ->
        :ok

      routine ->
        workspace = Path.expand(routine.workspace)
        File.write!(Path.join(workspace, "journal.md"), render_journal(routine_id))
        File.write!(Path.join(workspace, "TODO.md"), render_todos(routine_id))
        :ok
    end
  end

  defp render_journal(routine_id) do
    entries =
      for entry <- journal(routine_id, 200) do
        title = if entry.title, do: " -- #{entry.title}", else: ""
        stamp = Calendar.strftime(entry.inserted_at, "%Y-%m-%d %H:%M UTC")
        "## #{stamp}#{title} (#{entry.source})\n\n#{String.trim(entry.body)}\n"
      end

    """
    # Journal

    <!-- generated by custode from the notebook database; edit via the
         dashboard, Custode console, or MCP tools, not this file -->

    #{Enum.join(entries, "\n")}
    """
  end

  defp render_todos(routine_id) do
    lines =
      for todo <- todos(routine_id, "all") do
        box = if todo.status == "done", do: "x", else: " "
        "- [#{box}] (##{todo.id}) #{todo.text}"
      end

    """
    # TODO

    <!-- generated by custode from the notebook database; edit via the
         dashboard, Custode console, or MCP tools, not this file -->

    #{Enum.join(lines, "\n")}
    """
  end

  defp after_mutation(routine_id) do
    render!(routine_id)
    Custode.PubSubBridge.broadcast({:notebook_changed, routine_id})
    :ok
  end
end
