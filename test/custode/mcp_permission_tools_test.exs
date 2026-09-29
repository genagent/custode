defmodule Custode.MCPPermissionToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Anubis.Server.{Frame, Response}
  alias Custode.{AgentAuthorizationSnapshot, Feed, Repo, Routine}
  alias Custode.MCP.PermissionTools.PermissionDecide

  setup do
    routine =
      tmp_workspace!()
      |> routine_fixture!(%{
        role: :backlog_worker,
        cron: :manual,
        repo: "acme/" <> uid("permission-core-repo")
      })

    revision = Routine.execution_revision(routine)
    assert :ok = AgentAuthorizationSnapshot.put(routine, revision)

    frame = %Frame{
      assigns: %{custode_identity: %{kind: :routine, id: routine.id}}
    }

    %{routine: routine, revision: revision, frame: frame}
  end

  test "allows an in-role read and records only exact-revision correlation", ctx do
    generation = Ecto.UUID.generate()
    turn_id = Ecto.UUID.generate()
    arc_id = "operator:" <> Ecto.UUID.generate()

    exact =
      insert_turn!(ctx.routine.id, ctx.revision,
        agent_generation: generation,
        agent_turn_id: turn_id,
        arc_id: arc_id
      )

    on_exit(fn -> delete_job(exact) end)

    input = %{"repo" => ctx.routine.repo, "secret" => "must-not-enter-the-audit"}

    assert %{"behavior" => "allow", "updatedInput" => ^input} =
             decision(
               %{
                 tool_name: "mcp__custode__repo_list_issues",
                 input: input,
                 tool_use_id: "toolu_core_test"
               },
               ctx.frame
             )

    assert [audit | _rest] =
             Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 10)

    assert audit["decision"] == "allow"
    assert audit["reason"] == "read_only"
    assert audit["execution_revision"] == ctx.revision
    assert audit["agent_generation"] == generation
    assert audit["agent_turn_id"] == turn_id
    assert audit["arc_id"] == arc_id
    refute Jason.encode!(audit) =~ "must-not-enter-the-audit"
    refute Map.has_key?(audit, "input")
  end

  test "denies recursion, non-Custode, unknown, out-of-role, and non-read tools", ctx do
    requests = [
      {"mcp__custode__permission_decide", :broker_recursion},
      {"Bash", :outside_custode},
      {"Edit", :outside_custode},
      {"Write", :outside_custode},
      {"mcp__github__get_issue", :outside_custode},
      {"mcp__custode__no_such_tool", :unknown_tool},
      {"mcp__custode__list_attention", :outside_capability_set},
      {"mcp__custode__journal_append", :not_read_only}
    ]

    for {tool, reason} <- requests do
      assert %{"behavior" => "deny", "message" => message} =
               decision(%{tool_name: tool, input: %{}}, ctx.frame)

      assert message =~ "permission denied"

      assert [audit | _rest] =
               Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 1)

      assert audit["decision"] == "deny"
      assert audit["reason"] == Atom.to_string(reason)
      assert audit["execution_revision"] == ctx.revision
      assert String.length(audit["requested_tool"]) <= 200
    end
  end

  test "caps caller-controlled tool names in the audit", ctx do
    requested_tools = [
      "mcp__external__" <> String.duplicate("x", 1_000),
      "mcp__external__a" <> String.duplicate("\u0301", 100_000)
    ]

    for requested_tool <- requested_tools do
      assert %{"behavior" => "deny"} =
               decision(%{tool_name: requested_tool, input: %{}}, ctx.frame)

      assert [audit | _rest] =
               Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 1)

      assert byte_size(audit["requested_tool"]) <= 200
      assert byte_size(audit["summary"]) < 300
    end
  end

  test "denies malformed, unauthenticated, non-routine, and unavailable authorization", ctx do
    assert %{"behavior" => "deny", "message" => malformed} =
             decision(%{input: %{}}, ctx.frame)

    assert malformed =~ "tool_name"

    assert %{"behavior" => "deny", "message" => unauthenticated} =
             decision(%{tool_name: "mcp__custode__repo_list_issues", input: %{}}, %Frame{})

    assert unauthenticated =~ "authenticated routine"

    operator = %Frame{assigns: %{custode_identity: %{kind: :operator, id: "operator"}}}

    assert %{"behavior" => "deny", "message" => operator_denial} =
             decision(%{tool_name: "mcp__custode__repo_list_issues", input: %{}}, operator)

    assert operator_denial =~ "authenticated routine"

    unknown_id = uid("missing-routine")
    unknown = %Frame{assigns: %{custode_identity: %{kind: :routine, id: unknown_id}}}

    assert %{"behavior" => "deny", "message" => unavailable} =
             decision(%{tool_name: "mcp__custode__repo_list_issues", input: %{}}, unknown)

    assert unavailable =~ "authorization snapshot is unavailable"
  end

  test "ambiguous exact-revision turns omit correlation rather than guessing", ctx do
    first = insert_turn!(ctx.routine.id, ctx.revision)
    second = insert_turn!(ctx.routine.id, ctx.revision)
    on_exit(fn -> Enum.each([first, second], &delete_job/1) end)

    assert %{"behavior" => "allow"} =
             decision(
               %{tool_name: "mcp__custode__repo_list_issues", input: %{}},
               ctx.frame
             )

    assert [audit | _rest] =
             Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 1)

    refute Map.has_key?(audit, "agent_generation")
    refute Map.has_key?(audit, "agent_turn_id")
    refute Map.has_key?(audit, "arc_id")
  end

  test "keeps the active turn's captured role after the roster role changes", ctx do
    turn = insert_turn!(ctx.routine.id, ctx.revision)
    on_exit(fn -> delete_job(turn) end)

    current_routines = Application.fetch_env!(:custode, :routines)

    put_env!(
      :routines,
      Enum.map(current_routines, fn
        %{id: id} = routine when id == ctx.routine.id -> %{routine | role: :caretaker}
        routine -> routine
      end)
    )

    current = Routine.get(ctx.routine.id)
    assert current.role == :caretaker
    refute Routine.execution_revision(current) == ctx.revision

    assert %{"behavior" => "deny"} =
             decision(
               %{tool_name: "mcp__custode__list_attention", input: %{}},
               ctx.frame
             )

    assert %{"behavior" => "allow"} =
             decision(
               %{tool_name: "mcp__custode__repo_list_issues", input: %{}},
               ctx.frame
             )

    assert [audit | _rest] =
             Feed.recent_by_event("permission_decision", agent: ctx.routine.id, limit: 1)

    assert audit["execution_revision"] == ctx.revision
  end

  defp decision(params, frame) do
    {:reply, response, _frame} = PermissionDecide.execute(params, frame)

    assert %{"content" => [%{"type" => "text", "text" => text}], "isError" => false} =
             Response.to_protocol(response)

    Jason.decode!(text)
  end

  defp insert_turn!(agent_id, revision, meta \\ []) do
    generation = Keyword.get(meta, :agent_generation, Ecto.UUID.generate())
    turn_id = Keyword.get(meta, :agent_turn_id, Ecto.UUID.generate())
    arc_id = Keyword.get(meta, :arc_id, "scheduled:" <> Ecto.UUID.generate())

    %{"prompt" => "permission correlation fixture"}
    |> Oban.Job.new(
      worker: ObanClaude.Agent.Job,
      queue: :agents,
      meta: %{
        "agent_id" => agent_id,
        "agent_generation" => generation,
        "agent_turn_id" => turn_id,
        "arc_id" => arc_id,
        "config_revision" => revision
      }
    )
    |> Ecto.Changeset.change(state: "suspended")
    |> Repo.insert!()
  end

  defp delete_job(job) do
    case Repo.get(Oban.Job, job.id) do
      nil -> :ok
      current -> Repo.delete!(current)
    end
  end
end
