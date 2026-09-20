defmodule Custode.MCPBlindCallTest do
  # A blind call to a self-scoped tool (#483). The `claude` CLI defers MCP tool
  # schemas, so an agent's first call to a custode tool is a guess at the
  # parameter names. The guess has to either work or come back as a tool error
  # the model can read, never as the protocol error "Invalid params".
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Anubis.Server.Handlers
  alias Custode.MCP.AskTools.AskOperator
  alias Custode.MCP.MemoryTools
  alias Custode.MCP.NotebookTools
  alias Custode.MCP.RepoTools
  alias Custode.MCP.Tools

  @operator %Anubis.Server.Frame{}

  @self_scoped [
    {NotebookTools.JournalAppend, "routine_id"},
    {NotebookTools.SetPanel, "routine_id"},
    {NotebookTools.CompactJournal, "routine_id"},
    {NotebookTools.TodoAdd, "routine_id"},
    {NotebookTools.TodoList, "routine_id"},
    {NotebookTools.InboxList, "routine_id"},
    {NotebookTools.InboxMarkFiled, "routine_id"},
    {MemoryTools.Remember, "agent_id"},
    {MemoryTools.Recall, "agent_id"},
    {MemoryTools.Forget, "agent_id"},
    {AskOperator, "agent_id"},
    {RepoTools.DraftIssues, "routine_id"},
    {RepoTools.FileDrafts, "routine_id"}
  ]

  defp frame_for(kind, id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}

  # The path a `tools/call` from the CLI takes: anubis validates the arguments
  # (string keys, as they arrive off the wire) against the schema, and only
  # then reaches execute/2. A `{:error, _, _}` here is what the model sees as
  # the two words "Invalid params".
  defp wire(tool, arguments, frame) do
    request = %{"params" => %{"name" => tool, "arguments" => arguments}}
    Handlers.Tools.handle_call(request, frame, Custode.MCP.Server)
  end

  defp wire_json(
         {:reply, %{"content" => [%{"text" => text} | _rest], "isError" => false}, _frame}
       ),
       do: Jason.decode!(text)

  defp wire_error(
         {:reply, %{"content" => [%{"text" => text} | _rest], "isError" => true}, _frame}
       ),
       do: text

  defp journal_bodies(routine_id),
    do: routine_id |> Custode.Notebook.journal(50) |> Enum.map(& &1.body)

  setup do
    # asks feed the fleet-wide attention count other modules assert on
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine, workspace: workspace, own: frame_for(:routine, routine.id)}
  end

  describe "the schemas" do
    test "every self-scoped tool declares both identity names, and requires neither" do
      for {tool, documented} <- @self_scoped do
        schema = tool.input_schema()
        required = Map.get(schema, "required", [])

        assert %{"routine_id" => _, "agent_id" => _} = schema["properties"], inspect(tool)
        refute "routine_id" in required, inspect(tool)
        refute "agent_id" in required, inspect(tool)

        [aliased] = ["routine_id", "agent_id"] -- [documented]
        assert schema["properties"][aliased]["description"] =~ "alias for #{documented}"
      end
    end

    test "a content field is no longer the schema's to require; the draft tools keep theirs" do
      for {tool, _documented} <- @self_scoped,
          tool not in [RepoTools.DraftIssues, RepoTools.FileDrafts] do
        assert Map.get(tool.input_schema(), "required", []) == [], inspect(tool)
      end

      assert Enum.sort(RepoTools.DraftIssues.input_schema()["required"]) == ["issues", "repo"]
      assert RepoTools.FileDrafts.input_schema()["required"] == ["batch_id"]
    end
  end

  describe "the id defaults to the caller" do
    test "a routine's journal_append with NO id writes to its own journal", ctx do
      body = uid("swept")

      json = wire_json(wire("journal_append", %{"title" => "sweep", "body" => body}, ctx.own))

      assert is_integer(json["entry_id"])
      assert body in journal_bodies(ctx.routine.id)
    end

    # the live transcript's `inbox_list {}` and `todo_list {}`
    test "the reads default too: inbox_list {} and todo_list {}", ctx do
      File.write!(Path.join([ctx.workspace, "inbox", "note.md"]), "rotate the api key\n")
      {:ok, _todo} = Custode.Notebook.todo_add(ctx.routine.id, "rotate key")

      assert %{"notes" => [%{"name" => "note.md"}]} = wire_json(wire("inbox_list", %{}, ctx.own))

      assert %{"todos" => [%{"text" => "rotate key"}]} =
               wire_json(wire("todo_list", %{}, ctx.own))
    end

    test "a sub-agent is an agent too: its memory defaults to its own id" do
      sub = uid("sub")
      frame = frame_for(:sub_agent, sub)

      assert %{"remembered" => "pref"} =
               tool_json(MemoryTools.Remember.execute(%{key: "pref", value: "be brief"}, frame))

      assert {:ok, "be brief"} = Custode.Memory.recall(sub, "pref")

      assert %{"value" => "be brief"} =
               tool_json(MemoryTools.Recall.execute(%{key: "pref"}, frame))

      assert %{"forgot" => "pref"} = tool_json(MemoryTools.Forget.execute(%{key: "pref"}, frame))
      assert :error = Custode.Memory.recall(sub, "pref")
    end

    test "a routine's drafts are its own without naming itself", ctx do
      repo = "acme/" <> uid("served")

      json =
        tool_json(
          RepoTools.DraftIssues.execute(%{repo: repo, issues: [%{title: "chore: x"}]}, ctx.own)
        )

      assert [%{routine_id: routine_id}] = Custode.Drafts.entries(json["batch_id"])
      assert routine_id == ctx.routine.id

      # and another caller's default id does not reach that batch
      intruder = frame_for(:routine, uid("intruder"))

      assert tool_error(RepoTools.FileDrafts.execute(%{batch_id: json["batch_id"]}, intruder)) =~
               "belongs to another routine"
    end
  end

  describe "the alias" do
    # The operator frame is what proves the alias reaches execute/2. Peri does
    # not reject a key the schema leaves out, it DROPS it, so an undeclared
    # alias from a routine would still appear to work (the caller default
    # covers for it) while the same call from the operator lost its id.
    test "recall takes routine_id, the first failing call of the live transcript", ctx do
      key = uid("fact")
      :ok = Custode.Memory.remember(ctx.routine.id, key, "kept")

      for frame <- [ctx.own, @operator] do
        json = wire_json(wire("recall", %{"routine_id" => ctx.routine.id}, frame))
        assert %{"key" => key, "value" => "kept"} in json["memories"]
      end
    end

    test "journal_append takes agent_id", ctx do
      for frame <- [ctx.own, @operator] do
        body = uid("aliased")
        args = %{"agent_id" => ctx.routine.id, "body" => body}

        assert is_integer(wire_json(wire("journal_append", args, frame))["entry_id"])
        assert body in journal_bodies(ctx.routine.id)
      end
    end

    test "a blank id is no id" do
      assert Tools.self_id(%{routine_id: "  ", agent_id: "real"}, @operator) == "real"
      assert Tools.self_id(%{routine_id: "", agent_id: ""}, @operator) == nil
      assert Tools.self_id(%{routine_id: "first", agent_id: "second"}, @operator) == "first"
    end
  end

  describe "a missing content field" do
    # THE live failure: `tower-resilience` sent `text`, then `entry`, for
    # journal_append's `body`. Both came back as "Invalid params", it never
    # learned the name, and the sweep went unjournaled.
    test "journal_append with text instead of body says which field and what it is", ctx do
      guesses = [
        %{"routine_id" => ctx.routine.id, "title" => "sweep", "text" => "what I did"},
        %{"agent_id" => ctx.routine.id, "title" => "sweep", "entry" => "what I did"}
      ]

      for arguments <- guesses do
        error = wire_error(wire("journal_append", arguments, ctx.own))

        assert error =~ "missing `body`"
        assert error =~ "the entry text"
        assert error =~ "ToolSearch"
      end

      refute "what I did" in journal_bodies(ctx.routine.id)
    end

    test "every content field answers the same way, and nothing raises", ctx do
      cases = [
        {"set_panel", %{}, "html"},
        {"compact_journal", %{}, "summary"},
        {"todo_add", %{}, "text"},
        {"inbox_mark_filed", %{}, "name"},
        {"remember", %{"value" => "v"}, "key"},
        {"remember", %{"key" => "k"}, "value"},
        {"forget", %{}, "key"},
        {"ask_operator", %{}, "question"}
      ]

      for {tool, arguments, field} <- cases do
        assert wire_error(wire(tool, arguments, ctx.own)) =~ "missing `#{field}`: ", tool
      end
    end

    test "need/3 takes a value, refuses nil and blank" do
      assert {:ok, "x"} = Tools.need(%{body: "x"}, :body, "the text")
      assert {:ok, 0} = Tools.need(%{count: 0}, :count, "how many")
      assert {:ok, false} = Tools.need(%{flag: false}, :flag, "on or off")
      assert {:error, "missing `body`: the text. " <> _rest} = Tools.need(%{}, :body, "the text")
      assert {:error, _message} = Tools.need(%{body: " \n"}, :body, "the text")
    end
  end

  describe "authorization is unchanged" do
    test "a routine naming a SIBLING is still refused, under either name", ctx do
      sibling = uid("sibling")

      for name <- ["routine_id", "agent_id"] do
        body = uid("sneaky")

        assert wire_error(wire("journal_append", %{name => sibling, "body" => body}, ctx.own)) =~
                 "may not write"

        assert wire_error(
                 wire("remember", %{name => sibling, "key" => "k", "value" => "v"}, ctx.own)
               ) =~
                 "may not write"

        assert wire_error(
                 wire("ask_operator", %{name => sibling, "question" => "theirs?"}, ctx.own)
               ) =~
                 "identity"

        refute body in journal_bodies(sibling)
      end

      assert Custode.Memory.recall(sibling) == []
      refute Enum.any?(Custode.Asks.open(), &(&1.agent_id == sibling))
    end

    test "the operator with no id is asked whose records, not crashed" do
      calls = [
        {"journal_append", %{"body" => "whose?"}},
        {"todo_add", %{"text" => "whose?"}},
        {"todo_list", %{}},
        {"inbox_list", %{}},
        {"remember", %{"key" => "k", "value" => "v"}},
        {"recall", %{}},
        {"ask_operator", %{"question" => "whose?"}},
        {"repo_draft_issues", %{"repo" => "acme/x", "issues" => [%{"title" => "chore: x"}]}},
        {"repo_file_drafts", %{"batch_id" => "batch-none"}}
      ]

      for {tool, arguments} <- calls do
        error = wire_error(wire(tool, arguments, @operator))

        assert error =~ "whose records", tool
        assert error =~ "routine_id", tool
      end
    end
  end

  describe "the documented parameters still work" do
    test "notebook: todo_add and todo_list with routine_id", ctx do
      id = ctx.routine.id

      assert %{"todo_id" => todo_id} =
               tool_json(
                 NotebookTools.TodoAdd.execute(%{routine_id: id, text: "rotate"}, @operator)
               )

      assert %{"todos" => [%{"id" => ^todo_id, "text" => "rotate"}]} =
               tool_json(NotebookTools.TodoList.execute(%{routine_id: id}, @operator))
    end

    test "memory: remember, recall and forget with agent_id" do
      id = uid("mem")

      assert %{"remembered" => "pref"} =
               tool_json(
                 MemoryTools.Remember.execute(%{agent_id: id, key: "pref", value: "v"}, @operator)
               )

      assert %{"memories" => [%{"key" => "pref", "value" => "v"}]} =
               tool_json(MemoryTools.Recall.execute(%{agent_id: id}, @operator))

      assert %{"forgot" => "pref"} =
               tool_json(MemoryTools.Forget.execute(%{agent_id: id, key: "pref"}, @operator))
    end

    test "ask: the operator files in an agent's name with agent_id", ctx do
      json =
        tool_json(AskOperator.execute(%{agent_id: ctx.routine.id, question: "which?"}, @operator))

      assert Custode.Asks.get(json["ask_id"]).agent_id == ctx.routine.id
    end

    test "repo: draft_issues with routine_id", ctx do
      repo = "acme/" <> uid("served")
      params = %{routine_id: ctx.routine.id, repo: repo, issues: [%{title: "chore: bump"}]}

      json = tool_json(RepoTools.DraftIssues.execute(params, ctx.own))

      assert [%{"title" => "chore: bump"}] = json["drafted"]
    end
  end
end
