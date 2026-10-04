defmodule Custode.ProjectProgressToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Anubis.Server.{Frame, Handlers}
  alias Custode.MCP.ProjectProgressTools.Read
  alias Custode.{OperatorMessage, Repo}

  @operator %Frame{assigns: %{custode_identity: %{kind: :operator, id: "operator"}}}

  setup do
    caretaker = uid("progress-caretaker")
    project = uid("progress-project")

    put_env!(:routines, [
      %{
        id: caretaker,
        role: :caretaker,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "coordinate"
      },
      %{
        id: project,
        role: :backlog_worker,
        provider: :codex,
        cron: :manual,
        workspace: tmp_workspace!(),
        prompt: "project work"
      }
    ])

    on_exit(fn ->
      Repo.delete_all(from(m in OperatorMessage, where: m.target_agent_id == ^project))
    end)

    %{caretaker: caretaker, project: project}
  end

  test "verified operator and caretaker receive full constraints and durable message ids", ctx do
    text = String.duplicate("retain the operator's constraint\n", 100)
    message = exchange!(ctx.project, text)

    for caller <- [@operator, frame(ctx.caretaker)] do
      result = Read.execute(%{routine_id: ctx.project}, caller) |> tool_json()
      assert result["schema_version"] == "custode.project_progress.v1"
      assert result["project"]["routine_id"] == ctx.project
      assert is_binary(result["observed_at"])
      assert result["conversation"]["page"] == "latest"
      assert result["conversation"]["snapshot_id"] == message.id
      assert [exchange] = result["conversation"]["exchanges"]
      assert [%{"id" => id, "text" => ^text}] = exchange["prompts"]
      assert id == message.message_id
      assert exchange["result"] == message.result
      assert result["links"]["conversation"] =~ ctx.project
    end

    assert Repo.get!(OperatorMessage, message.id) == message
  end

  test "direct calls cannot manufacture operator or caretaker authority", ctx do
    message = exchange!(ctx.project, "operator-only project evidence")

    for caller <- [
          %Frame{},
          %Frame{assigns: %{custode_identity: %{kind: :operator}}},
          frame(ctx.project),
          frame(ctx.caretaker, :sub_agent),
          frame(uid("unknown-caretaker"))
        ] do
      error =
        Read.execute(%{routine_id: ctx.project, actor: %{kind: :operator}}, caller)
        |> tool_error()

      assert error != ""
      refute error =~ message.prompt
    end

    assert Repo.get!(OperatorMessage, message.id) == message
  end

  test "wire schema preserves page cursors while a fresh read sees newer operator input", ctx do
    older = exchange!(ctx.project, "keep the release manual")
    latest = exchange!(ctx.project, "focus on the API first")

    first = wire_json(%{"routine_id" => ctx.project, "limit" => 1}, frame(ctx.caretaker))
    assert first["conversation"]["has_older"]
    assert is_binary(first["conversation"]["before"])
    assert first["conversation"]["snapshot_id"] == latest.id
    newest = exchange!(ctx.project, "new operator constraint: do not publish")

    previous =
      wire_json(
        %{"routine_id" => ctx.project, "limit" => 1, "before" => first["conversation"]["before"]},
        frame(ctx.caretaker)
      )

    assert previous["conversation"]["page"] == "older"
    assert previous["conversation"]["snapshot_id"] == latest.id
    assert [exchange] = previous["conversation"]["exchanges"]
    assert [%{"id" => id}] = exchange["prompts"]
    assert id == older.message_id

    fresh = wire_json(%{"routine_id" => ctx.project, "limit" => 1}, frame(ctx.caretaker))
    assert fresh["conversation"]["snapshot_id"] == newest.id
    assert [exchange] = fresh["conversation"]["exchanges"]
    assert [%{"text" => "new operator constraint: do not publish"}] = exchange["prompts"]
  end

  test "missing targets and invalid bounds return readable tool errors", ctx do
    assert wire_error(%{}, @operator) =~ "routine_id"
    assert Read.execute(%{routine_id: uid("missing")}, @operator) |> tool_error() =~ "unknown"

    for limit <- [0, 21, 1.5, "5"] do
      assert Read.execute(%{routine_id: ctx.project, limit: limit}, @operator) |> tool_error() =~
               "limit"
    end

    assert wire_error(%{"routine_id" => ctx.project, "limit" => 21}, @operator) =~ "limit"

    assert wire_error(
             %{"routine_id" => ctx.project, "before" => "2026-10-03T12:00:00Z"},
             @operator
           ) =~ "before"

    assert Read.execute(%{routine_id: ctx.project, before: 12}, @operator) |> tool_error() =~
             "before"
  end

  defp exchange!(routine_id, prompt) do
    id = uid("progress-message")

    OperatorMessage.create_changeset(%{
      message_id: id,
      caller_kind: "operator",
      caller_id: "operator",
      transport: "mcp",
      target_agent_id: routine_id,
      idempotency_key: id,
      prompt_hash: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower),
      prompt: prompt,
      provider_correlation_id: id,
      provider: "codex",
      status: "completed",
      delivery: "delivered",
      result: %{"output" => "Evidence retained for " <> prompt}
    })
    |> Repo.insert!()
  end

  defp frame(id, kind \\ :routine),
    do: %Frame{assigns: %{custode_identity: %{kind: kind, id: id}}}

  defp wire(arguments, frame) do
    Handlers.Tools.handle_call(
      %{"params" => %{"name" => "project_progress", "arguments" => arguments}},
      frame,
      Custode.MCP.Server
    )
  end

  defp wire_json(arguments, frame) do
    {:reply, %{"isError" => false, "content" => [%{"text" => text} | _]}, _} =
      wire(arguments, frame)

    Jason.decode!(text)
  end

  defp wire_error(arguments, frame) do
    {:reply, %{"isError" => true, "content" => [%{"text" => text} | _]}, _} =
      wire(arguments, frame)

    text
  end
end
