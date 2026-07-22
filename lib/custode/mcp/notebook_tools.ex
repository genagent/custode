defmodule Custode.MCP.NotebookTools do
  @moduledoc """
  The notebook write path for agents: journal, todos, and mechanical inbox
  bookkeeping, all against the database (see `Custode.Notebook`) instead of
  file edits -- so a routine agent needs NO filesystem write permission for
  its bookkeeping.

  Identity caveat: tool calls carry no caller identity, so `routine_id` is a
  trusted parameter. Fine on a localhost demo; per-agent credentials are the
  fix before any of this leaves the machine.
  """

  @doc false
  def fetch_routine(routine_id) do
    case Custode.Routine.get(routine_id) do
      nil -> {:error, "unknown routine #{inspect(routine_id)}"}
      routine -> {:ok, routine}
    end
  end
end

defmodule Custode.MCP.NotebookTools.JournalAppend do
  @moduledoc "Append an entry to a routine's journal (the database is the source of truth; journal.md re-renders)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, required: true)
    field(:body, :string, required: true, description: "the entry text (markdown ok)")
    field(:title, :string, description: "optional short title")
  end

  @impl true
  def execute(%{routine_id: routine_id, body: body} = params, frame) do
    case check_self(frame, routine_id) do
      :ok ->
        {:ok, entry} =
          Custode.Notebook.journal_append(routine_id, body,
            title: params[:title],
            source: "sweep"
          )

        reply(frame, %{entry_id: entry.id})

      {:error, message} ->
        fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.SetPanel do
  @moduledoc """
  Propose an HTML panel for your OWN dashboard page (#100). The operator
  approves it before it renders, and it renders only inside a locked-down
  iframe (no scripts run). Inline SVG and CSS work, so this is for a real
  view -- a table of what you watch, a chart, a diagram -- that prose in the
  journal cannot give. Self-scoped; refused when panels are turned off.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, required: true)

    field(:html, :string,
      required: true,
      description: "the panel markup -- inline SVG/CSS only, no scripts (they will not run)"
    )
  end

  @impl true
  def execute(%{routine_id: routine_id, html: html}, frame) do
    with :ok <- check_self(frame, routine_id),
         {:ok, row} <- Custode.Panels.set(routine_id, html) do
      reply(frame, %{status: row.status})
    else
      {:error, :too_large} -> fail(frame, "panel too large (20KB max)")
      {:error, :panels_off} -> fail(frame, "agent panels are turned off")
      {:error, message} -> fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.CompactJournal do
  @moduledoc """
  Distill your OWN journal (#214): pass a summary that captures what your
  current journal entries still say, and every live entry is folded into it
  -- your journal.md shrinks to the summary plus what happens next, and the
  originals age out of the database. Use this when your journal has grown
  large; it is your memory hygiene, not deletion. Self-scoped.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, required: true)

    field(:summary, :string,
      required: true,
      description: "the distillation: what your journal so far still means, in a few lines"
    )
  end

  @impl true
  def execute(%{routine_id: routine_id, summary: summary}, frame) do
    case check_self(frame, routine_id) do
      :ok ->
        {:ok, %{summarized: count}} = Custode.Notebook.compact_journal(routine_id, summary)
        reply(frame, %{summarized: count})

      {:error, message} ->
        fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.TodoAdd do
  @moduledoc "Add an open todo to a routine's list."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, required: true)
    field(:text, :string, required: true)
  end

  @impl true
  def execute(%{routine_id: routine_id, text: text}, frame) do
    case check_self(frame, routine_id) do
      :ok -> add(routine_id, text, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp add(routine_id, text, frame) do
    {:ok, todo} = Custode.Notebook.todo_add(routine_id, text, source: "sweep")
    reply(frame, %{todo_id: todo.id})
  end
end

defmodule Custode.MCP.NotebookTools.TodoList do
  @moduledoc "A routine's todos: open (default), done, or all."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, required: true)
    field(:status, :string, description: "one of \"open\" (default), \"done\", \"all\"")
  end

  @impl true
  def execute(%{routine_id: routine_id} = params, frame) do
    status = params[:status] || "open"

    if status in ~w(open done all) do
      todos =
        for todo <- Custode.Notebook.todos(routine_id, status) do
          %{id: todo.id, text: todo.text, status: todo.status}
        end

      reply(frame, %{todos: todos})
    else
      fail(frame, "unknown status #{inspect(status)}; expected \"open\", \"done\", or \"all\"")
    end
  end
end

defmodule Custode.MCP.NotebookTools.TodoComplete do
  @moduledoc "Mark a todo done by its id (get ids from todo_list)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:todo_id, :integer, required: true)
  end

  @impl true
  def execute(%{todo_id: todo_id}, frame) do
    case Custode.Notebook.todo_complete(todo_id) do
      {:ok, todo} -> reply(frame, %{todo_id: todo.id, status: todo.status})
      {:error, :not_found} -> fail(frame, "no todo ##{todo_id}")
    end
  end
end

defmodule Custode.MCP.NotebookTools.InboxList do
  @moduledoc "The routine's unfiled inbox notes, names and contents in one call."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.MCP.NotebookTools

  schema do
    field(:routine_id, :string, required: true)
  end

  @impl true
  def execute(%{routine_id: routine_id}, frame) do
    case NotebookTools.fetch_routine(routine_id) do
      {:ok, routine} -> reply(frame, %{notes: Custode.Notebook.unfiled_notes(routine)})
      {:error, message} -> fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.InboxMarkFiled do
  @moduledoc "Mark an inbox note as FILED after journaling it (idempotent)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.MCP.NotebookTools

  schema do
    field(:routine_id, :string, required: true)
    field(:name, :string, required: true, description: "the note's file name (not a path)")
  end

  @impl true
  def execute(%{routine_id: routine_id, name: name}, frame) do
    case check_self(frame, routine_id) do
      :ok -> mark(routine_id, name, frame)
      {:error, message} -> fail(frame, message)
    end
  end

  defp mark(routine_id, name, frame) do
    with {:ok, routine} <- NotebookTools.fetch_routine(routine_id),
         :ok <- safe_mark(routine, name) do
      reply(frame, %{filed: name})
    else
      {:error, message} -> fail(frame, message)
    end
  end

  defp safe_mark(routine, name) do
    Custode.Notebook.mark_filed!(routine, name)
  rescue
    error in [ArgumentError, File.Error] -> {:error, Exception.message(error)}
  end
end
