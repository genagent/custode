defmodule Custode.MCPNotebookAuthorizationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, AgentHandoff, Notebook, Repo, Routine}
  alias Custode.MCP.NotebookTools

  setup do
    id = uid("notebook-authorization")
    old_workspace = tmp_workspace!()
    old_working_dir = tmp_workspace!()
    new_workspace = tmp_workspace!()
    new_working_dir = tmp_workspace!()

    put_env!(:routines, [
      %{
        id: id,
        role: :backlog_worker,
        provider: :claude,
        cron: :manual,
        workspace: old_workspace,
        working_dir: old_working_dir,
        prompt: "old contract"
      }
    ])

    old_routine = Routine.get(id)
    old_revision = Routine.execution_revision(old_routine)
    assert :ok = AgentAuthorizationSnapshot.put(old_routine, old_revision)

    job =
      %{"prompt" => "keep using the captured notebook paths"}
      |> Oban.Job.new(
        worker: ObanClaude.Agent.Job,
        queue: :agents,
        meta: %{
          "agent_id" => id,
          "agent_generation" => Ecto.UUID.generate(),
          "agent_turn_id" => Ecto.UUID.generate(),
          "config_revision" => old_revision
        }
      )
      |> Ecto.Changeset.change(state: "suspended")
      |> Repo.insert!()

    Application.put_env(:custode, :routines, [
      %{
        id: id,
        role: :backlog_worker,
        provider: :claude,
        cron: :manual,
        workspace: new_workspace,
        working_dir: new_working_dir,
        prompt: "new contract"
      }
    ])

    on_exit(fn ->
      Repo.delete_all(from(job_row in Oban.Job, where: job_row.id == ^job.id))
      Repo.delete_all(from(entry in Notebook.JournalEntry, where: entry.routine_id == ^id))
      Repo.delete_all(from(todo in Notebook.Todo, where: todo.routine_id == ^id))

      Repo.delete_all(
        from(snapshot in AgentAuthorizationSnapshot, where: snapshot.routine_id == ^id)
      )
    end)

    assert %{workspace: ^new_workspace, working_dir: ^new_working_dir} = Routine.get(id)

    assert {:ok,
            %{
              execution_revision: ^old_revision,
              workspace: ^old_workspace,
              working_dir: ^old_working_dir
            }} = AgentHandoff.authorization_routine(id)

    %{
      frame: %Anubis.Server.Frame{
        assigns: %{custode_identity: %{kind: :routine, id: id}}
      },
      id: id,
      new_workspace: new_workspace,
      old_workspace: old_workspace
    }
  end

  test "inbox effects stay in the workspace captured by the active turn", ctx do
    old_note = Path.join([ctx.old_workspace, "inbox", "note.md"])
    new_note = Path.join([ctx.new_workspace, "inbox", "note.md"])
    File.write!(old_note, "old revision note\n")
    File.write!(new_note, "new roster note\n")

    assert %{"notes" => [%{"name" => "note.md", "content" => "old revision note\n"}]} =
             %{}
             |> NotebookTools.InboxList.execute(ctx.frame)
             |> tool_json()

    assert %{"filed" => "note.md"} =
             %{name: "note.md"}
             |> NotebookTools.InboxMarkFiled.execute(ctx.frame)
             |> tool_json()

    assert File.read!(old_note) =~ ~r/^FILED \d{4}-\d{2}-\d{2}\n\nold revision note/
    assert File.read!(new_note) == "new roster note\n"
  end

  test "journal and todo mutations render into the active turn's captured workspace", ctx do
    new_journal = Path.join(ctx.new_workspace, "journal.md")
    new_todos = Path.join(ctx.new_workspace, "TODO.md")
    File.write!(new_journal, "new journal sentinel\n")
    File.write!(new_todos, "new todo sentinel\n")

    assert %{"entry_id" => entry_id} =
             %{body: "old revision journal entry"}
             |> NotebookTools.JournalAppend.execute(ctx.frame)
             |> tool_json()

    assert is_integer(entry_id)
    assert File.read!(Path.join(ctx.old_workspace, "journal.md")) =~ "old revision journal entry"
    assert File.read!(new_journal) == "new journal sentinel\n"

    assert %{"summarized" => 1} =
             %{summary: "old revision summary"}
             |> NotebookTools.CompactJournal.execute(ctx.frame)
             |> tool_json()

    assert File.read!(Path.join(ctx.old_workspace, "journal.md")) =~ "old revision summary"
    assert File.read!(new_journal) == "new journal sentinel\n"

    assert %{"todo_id" => todo_id} =
             %{text: "old revision todo"}
             |> NotebookTools.TodoAdd.execute(ctx.frame)
             |> tool_json()

    assert File.read!(Path.join(ctx.old_workspace, "TODO.md")) =~
             "- [ ] (##{todo_id}) old revision todo"

    assert File.read!(new_todos) == "new todo sentinel\n"

    assert %{"todo_id" => ^todo_id, "status" => "done"} =
             %{todo_id: todo_id}
             |> NotebookTools.TodoComplete.execute(ctx.frame)
             |> tool_json()

    assert File.read!(Path.join(ctx.old_workspace, "TODO.md")) =~
             "- [x] (##{todo_id}) old revision todo"

    assert File.read!(new_todos) == "new todo sentinel\n"
  end
end
