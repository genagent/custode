defmodule Custode.MCP.NotebookTools do
  @moduledoc """
  The notebook tools for agents: journal reads and writes, todos, and
  mechanical inbox bookkeeping, all against the database (see
  `Custode.Notebook`) instead of file edits -- so a routine agent needs no
  filesystem access to read its journal or write its bookkeeping.

  Identity: the bearer token says who is calling, so `routine_id` is optional
  on every self-scoped tool here and `agent_id` is accepted as its alias
  (#483, see `Custode.MCP.Tools.self_id/2`). A content field is enforced in
  `execute/2` rather than by the schema, so leaving one out comes back as a
  tool error the calling model can read (`Custode.MCP.Tools.need/3`).
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

  @body "the entry text (markdown ok)"

  schema do
    field(:routine_id, :string, description: "whose journal (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:body, :string, description: @body)
    field(:title, :string, description: "optional short title")
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, body} <- need(params, :body, @body) do
      {:ok, entry} =
        Custode.Notebook.journal_append(routine_id, body,
          title: params[:title],
          source: "sweep"
        )

      reply(frame, %{entry_id: entry.id})
    else
      {:error, message} -> fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.JournalRead do
  @moduledoc """
  Read your own journal from the database, newest entries first. Defaults to
  the latest 20 live entries, matching journal.md's compaction semantics.
  Set live_only to false to include compacted entries until the janitor
  retires them. Only the authenticated operator may read another identity.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, description: "whose journal (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:limit, :integer, description: "max entries (default 20, range 1..100)")
    field(:search, :string, description: "case-insensitive search in entry title or body")
    field(:live_only, :boolean, description: "exclude compacted entries (default true)")
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id, :read),
         {:ok, limit} <- bounded_limit(params[:limit]) do
      entries =
        routine_id
        |> Custode.Notebook.journal(limit,
          search: params[:search],
          live_only: params[:live_only] != false
        )
        |> Enum.map(&Map.take(&1, [:id, :title, :body, :inserted_at, :compacted_at]))

      reply(frame, %{entries: entries})
    else
      {:error, message} -> fail(frame, message)
    end
  end

  # Peri's numeric range validator also accepts floats for an integer field.
  # Keep the schema's plain integer check, and enforce the bound here before
  # the value reaches Ecto's limit expression.
  defp bounded_limit(nil), do: {:ok, 20}
  defp bounded_limit(limit) when is_integer(limit) and limit in 1..100, do: {:ok, limit}
  defp bounded_limit(_limit), do: {:error, "limit must be a whole number from 1 through 100"}
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

  @html "the panel markup -- inline SVG/CSS only, no scripts (they will not run)"

  schema do
    field(:routine_id, :string, description: "whose page (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:html, :string, description: @html)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, html} <- need(params, :html, @html),
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

  @summary "the distillation: what your journal so far still means, in a few lines"

  schema do
    field(:routine_id, :string, description: "whose journal (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:summary, :string, description: @summary)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, summary} <- need(params, :summary, @summary) do
      {:ok, %{summarized: count}} = Custode.Notebook.compact_journal(routine_id, summary)
      reply(frame, %{summarized: count})
    else
      {:error, message} -> fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.TodoAdd do
  @moduledoc "Add an open todo to a routine's list."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @text "the todo, one line"

  schema do
    field(:routine_id, :string, description: "whose list (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:text, :string, description: @text)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, text} <- need(params, :text, @text) do
      add(routine_id, text, frame)
    else
      {:error, message} -> fail(frame, message)
    end
  end

  defp add(routine_id, text, frame) do
    {:ok, todo} = Custode.Notebook.todo_add(routine_id, text, source: "sweep")
    reply(frame, %{todo_id: todo.id})
  end
end

defmodule Custode.MCP.NotebookTools.SetNextBeat do
  @moduledoc """
  Ask for your next scheduled beat to be in N minutes instead of whenever your
  cron says (#526). Use it when you KNOW when there will be something to do:
  CI you started takes 40 minutes, a release you are waiting on lands
  tomorrow. One-shot: your cron beats are skipped until then, you run once at
  that time, and the request is gone. Clamped to the operator's bounds; the
  reply says what you got. An operator message, a sensor wake or an inbox
  note still reaches you at once, and clears the request.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  @minutes "minutes from now until your next scheduled beat"
  @reason "one line: what you are waiting for"

  schema do
    field(:routine_id, :string, description: "your own routine id (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:minutes, :integer, description: @minutes)
    field(:reason, :string, description: @reason)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, minutes} <- need(params, :minutes, @minutes),
         {:ok, reason} <- need(params, :reason, @reason) do
      set(routine_id, minutes, reason, frame)
    else
      {:error, message} -> fail(frame, message)
    end
  end

  defp set(routine_id, minutes, reason, frame) when is_integer(minutes) do
    {:ok, granted} = Custode.NextBeat.request(routine_id, minutes, reason: reason)

    Custode.Feed.record(%{
      event: "next_beat",
      agent: routine_id,
      minutes: granted.minutes,
      requested_minutes: minutes,
      reason: reason,
      summary: "next beat in #{granted.minutes}m: #{reason}"
    })

    reply(frame, %{
      next_beat_at: DateTime.to_iso8601(granted.at),
      minutes: granted.minutes,
      clamped: granted.clamped?
    })
  end

  defp set(_routine_id, _minutes, _reason, frame),
    do: fail(frame, "minutes must be a whole number")
end

defmodule Custode.MCP.NotebookTools.TodoList do
  @moduledoc "A routine's todos: open (default), done, or all."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:routine_id, :string, description: "whose list (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:status, :string, description: "one of \"open\" (default), \"done\", \"all\"")
  end

  # A read, so no check_self/2: reads are not scoped (transparency is a
  # feature), and the id only defaults to the caller (#483).
  @impl true
  def execute(params, frame) do
    status = params[:status] || "open"

    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- known_status(status) do
      todos =
        for todo <- Custode.Notebook.todos(routine_id, status) do
          %{id: todo.id, text: todo.text, status: todo.status}
        end

      reply(frame, %{todos: todos})
    else
      {:error, message} -> fail(frame, message)
    end
  end

  defp known_status(status) when status in ~w(open done all), do: :ok

  defp known_status(status),
    do: {:error, "unknown status #{inspect(status)}; expected \"open\", \"done\", or \"all\""}
end

defmodule Custode.MCP.NotebookTools.TodoComplete do
  @moduledoc "Mark a todo done by its id (get ids from todo_list)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:todo_id, :integer, required: true)
  end

  # A todo is addressed by a bare id, so the owner has to be looked up before
  # the write: this tool took no routine id and never called check_self/2, and
  # any agent could complete any agent's todo by counting (#528 found it).
  @impl true
  def execute(%{todo_id: todo_id}, frame) do
    with owner when is_binary(owner) <- Custode.Notebook.todo_owner(todo_id),
         :ok <- check_self(frame, owner),
         {:ok, todo} <- Custode.Notebook.todo_complete(todo_id) do
      reply(frame, %{todo_id: todo.id, status: todo.status})
    else
      {:error, message} when is_binary(message) -> fail(frame, message)
      _not_found -> fail(frame, "no todo ##{todo_id}")
    end
  end
end

defmodule Custode.MCP.NotebookTools.InboxList do
  @moduledoc "The routine's unfiled inbox notes, names and contents in one call."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.MCP.NotebookTools

  schema do
    field(:routine_id, :string, description: "whose inbox (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
  end

  # A read, so no check_self/2 (see TodoList).
  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         {:ok, routine} <- NotebookTools.fetch_routine(routine_id) do
      reply(frame, %{notes: Custode.Notebook.unfiled_notes(routine)})
    else
      {:error, message} -> fail(frame, message)
    end
  end
end

defmodule Custode.MCP.NotebookTools.InboxMarkFiled do
  @moduledoc "Mark an inbox note as FILED after journaling it (idempotent)."
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.MCP.NotebookTools

  @name "the note's file name (not a path)"

  schema do
    field(:routine_id, :string, description: "whose inbox (defaults to the caller)")
    field(:agent_id, :string, description: alias_for("routine_id"))
    field(:name, :string, description: @name)
  end

  @impl true
  def execute(params, frame) do
    with {:ok, routine_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, routine_id),
         {:ok, name} <- need(params, :name, @name) do
      mark(routine_id, name, frame)
    else
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
