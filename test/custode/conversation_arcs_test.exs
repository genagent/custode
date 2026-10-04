defmodule Custode.ConversationArcsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.{Agents, ConversationArcs, Repo, Routine}
  alias Custode.MCP.Identity
  alias Custode.Operator.Actions
  alias ObanClaude.Agent.{Job, Tick}

  setup do
    put_env!(:conversation_host_id, "test-host")
    :ok
  end

  test "an idle operator arc survives an agent restart and resumes its exact session" do
    routine = routine_fixture!(tmp_workspace!(), %{model: "haiku"})
    on_exit(fn -> Agents.stop_agent(routine.id) end)

    assert {:ok, :started} = Actions.message(routine.id, "first question")
    first = latest_turn(routine.id)
    assert first.meta["arc_id"] =~ "operator:"
    refute Map.has_key?(first.args, "resume")

    finish!(first, "operator-session")

    eventually(fn ->
      assert %{provider_session_id: "operator-session"} =
               ConversationArcs.read_model(routine.id).current
    end)

    assert :ok = Agents.stop_agent(routine.id)
    assert {:ok, delivery} = Actions.message(routine.id, "second question")
    assert delivery in [:started, :queued]

    second = latest_turn(routine.id, first.id)
    assert second.id != first.id
    assert second.meta["arc_id"] == first.meta["arc_id"]
    assert second.args["resume"] == "operator-session"
  end

  test "a fresh scheduled sweep between operator messages does not replace the operator arc" do
    routine = routine_fixture!(tmp_workspace!(), %{model: "haiku"})
    on_exit(fn -> Agents.stop_agent(routine.id) end)

    assert {:ok, :started} = Actions.message(routine.id, "remember this")
    operator_turn = latest_turn(routine.id)
    operator_arc = operator_turn.meta["arc_id"]
    finish!(operator_turn, "operator-session")

    assert :ok = Custode.RoutineTick.perform(%Oban.Job{args: %{"routine_id" => routine.id}})
    tick = latest_tick(routine.id)
    assert tick.args["arc_id"] =~ "scheduled:"
    assert tick.args["arc_id"] != operator_arc
    assert tick.args["session"] == "fresh"
    assert tick.args["start"]["session_arcs"][operator_arc] == "operator-session"

    assert :ok = Tick.perform(%Oban.Job{args: tick.args})
    sweep = latest_turn(routine.id, operator_turn.id)
    assert sweep.meta["arc_id"] == tick.args["arc_id"]
    refute Map.has_key?(sweep.args, "resume")
    finish!(sweep, "sweep-session")

    assert {:ok, :delivered} = Actions.message(routine.id, "what did you find?")
    follow_up = latest_turn(routine.id, sweep.id)
    assert follow_up.meta["arc_id"] == operator_arc
    assert follow_up.args["resume"] == "operator-session"
  end

  test "provider, host, workspace and execution contract changes create explicit generations" do
    workspace = tmp_workspace!()
    id = uid("rotate")

    put_env!(:routines, [
      %{id: id, cron: :manual, workspace: workspace, prompt: "sweep", model: "haiku"}
    ])

    first = Custode.Routine.get(id)
    assert {:ok, original} = ConversationArcs.prepare(first, :operator)

    put_env!(:conversation_host_id, "replacement-host")
    assert {:ok, changed_host} = ConversationArcs.prepare(first, :operator)
    assert changed_host.arc.id != original.arc.id
    assert changed_host.reason == :host_changed

    put_env!(:routines, [
      %{id: id, cron: :manual, workspace: workspace, prompt: "sweep", model: "sonnet"}
    ])

    assert {:ok, changed_model} = ConversationArcs.prepare(Custode.Routine.get(id), :operator)
    assert changed_model.arc.id != changed_host.arc.id
    assert changed_model.reason == :configuration_changed

    put_env!(:routines, [
      %{
        id: id,
        cron: :manual,
        workspace: workspace,
        prompt: "sweep",
        model: "sonnet",
        extra_allowed_tools: ["Bash(git status:*)"]
      }
    ])

    assert {:ok, changed_tools} = ConversationArcs.prepare(Custode.Routine.get(id), :operator)
    assert changed_tools.reason == :configuration_changed

    other_workspace = tmp_workspace!()

    put_env!(:routines, [
      %{
        id: id,
        cron: :manual,
        workspace: workspace,
        working_dir: other_workspace,
        prompt: "sweep",
        model: "sonnet"
      }
    ])

    assert {:ok, changed_workspace} =
             ConversationArcs.prepare(Custode.Routine.get(id), :operator)

    assert changed_workspace.reason == :workspace_changed

    put_env!(:routines, [
      %{
        id: id,
        provider: :codex,
        cron: :manual,
        workspace: workspace,
        working_dir: other_workspace,
        prompt: "sweep"
      }
    ])

    codex = Custode.Routine.get(id)
    assert {:ok, changed_provider} = ConversationArcs.prepare(codex, :operator)
    assert changed_provider.reason == :provider_changed
    assert ConversationArcs.seed_map(codex) == %{}

    assert [old, host, model, tools, moved, current] = ConversationArcs.history(id, "operator")
    assert old.state == "rotated"
    assert host.rotation_reason == "configuration_changed"
    assert model.rotation_reason == "configuration_changed"
    assert tools.rotation_reason == "workspace_changed"
    assert moved.rotation_reason == "provider_changed"
    assert current.state == "active"
  end

  test "a Codex credential refresh replaces the host without rotating its conversation arc" do
    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :codex,
        mcp: true,
        model: "gpt-5.6-sol"
      })

    _first_token = Identity.mint(:routine, routine.id)
    first_revision = routine.id |> Routine.get() |> Routine.execution_revision()
    assert {:ok, original} = ConversationArcs.prepare(Routine.get(routine.id), :operator)

    _replacement_token = Identity.mint(:routine, routine.id)
    current = Routine.get(routine.id)
    assert Routine.execution_revision(current) != first_revision

    assert {:ok, retained} = ConversationArcs.prepare(current, :operator)
    assert retained.arc.id == original.arc.id
    assert retained.reason == :no_session
    assert [active] = ConversationArcs.history(routine.id, "operator")
    assert active.state == "active"
  end

  test "a rejected provider session records and selects an explicit fresh fallback" do
    routine = routine_fixture!(tmp_workspace!(), %{model: "haiku"})
    assert {:ok, prepared} = ConversationArcs.prepare(routine, :operator)

    complete(prepared, :completed, "session-that-existed")
    complete(prepared, :session_rejected, "session-that-existed", :invalid_session)

    assert {:ok, fallback} = ConversationArcs.prepare(routine, :operator)
    assert fallback.arc.id == prepared.arc.id
    assert fallback.decision == :fresh_fallback
    assert fallback.reason == :resume_failed
    assert fallback.session == :fresh_fallback

    assert {:ok, recovery_prompt, opts} =
             ConversationArcs.operator_delivery(routine, "continue the comparison")

    assert recovery_prompt =~ "Custode continuity recovery"
    assert recovery_prompt =~ "recall the"
    assert recovery_prompt =~ "`#{routine.id}` notebook"
    assert recovery_prompt =~ "continue the comparison"
    assert opts[:session] == :fresh_fallback

    assert %{provider_session_id: nil, decision: "fresh_fallback", reason: "resume_failed"} =
             ConversationArcs.read_model(routine.id).current
  end

  test "specialist assignment arcs resume while one-shot jobs get distinct fresh arcs" do
    routine = routine_fixture!(tmp_workspace!(), %{model: "haiku"})

    assert {:ok, specialist} =
             ConversationArcs.prepare(routine, :specialist, arc_id: "issue-42")

    complete(specialist, :completed, "specialist-session")

    assert {:ok, resumed} =
             ConversationArcs.prepare(routine, :specialist, arc_id: "issue-42")

    assert resumed.arc_id == specialist.arc_id
    assert resumed.decision == :resume
    assert resumed.session_arcs == %{specialist.arc_id => "specialist-session"}

    assert {:ok, _first_args, first_job} = ConversationArcs.tick_args(routine, :job)
    assert {:ok, _second_args, second_job} = ConversationArcs.tick_args(routine, :job)
    assert first_job.arc_id != second_job.arc_id
    assert first_job.decision == :fresh
    assert second_job.decision == :fresh
  end

  test "inbox arcs are fresh and close after the delivery turn" do
    routine = routine_fixture!(tmp_workspace!(), %{model: "haiku"})

    assert {:ok, args, prepared} =
             ConversationArcs.tick_args(routine, :inbox, arc_id: "inbox:wake-1")

    assert args["session"] == "fresh"
    assert prepared.arc.kind == "inbox"
    assert prepared.arc.state == "active"

    complete(prepared, :completed, "inbox-session")

    assert [arc] = ConversationArcs.history(routine.id, "inbox:wake-1")
    assert arc.state == "completed"
    assert arc.last_outcome == "completed"
  end

  defp latest_turn(agent_id, after_id \\ 0) do
    eventually(fn ->
      job =
        "ObanClaude.Agent.Job"
        |> jobs_for()
        |> Enum.filter(&(&1.meta["agent_id"] == agent_id and &1.id > after_id))
        |> List.last()

      assert %{id: id} = job
      assert is_integer(id)
      job
    end)
  end

  defp latest_tick(agent_id) do
    eventually(fn ->
      job =
        "ObanClaude.Agent.Tick"
        |> jobs_for()
        |> Enum.filter(&(&1.args["agent_id"] == agent_id))
        |> List.last()

      assert %{id: id} = job
      assert is_integer(id)
      job
    end)
  end

  defp finish!(job, session_id) do
    :ok =
      Job.handle_result(
        result(session_id: session_id),
        %Oban.Job{id: job.id, meta: job.meta, attempt: 1, max_attempts: 1}
      )

    # handle_result/2 simulates the worker callback. Real Oban marks the row
    # terminal when that callback returns; mirror that physical boundary here.
    Oban.Job
    |> Repo.get!(job.id)
    |> Ecto.Changeset.change(state: "completed", completed_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, :idle} = Agents.await(job.meta["agent_id"], :idle, 1_000)
  end

  defp complete(prepared, outcome, session_id, outcome_reason \\ nil) do
    :ok =
      ConversationArcs.handle_event(
        [:oban_claude, :agent, :turn_completed],
        %{},
        %{
          agent_id: prepared.arc.routine_id,
          arc_id: prepared.arc_id,
          session_id: session_id,
          continuation_decision: :resume,
          continuation_reason: :session_available,
          outcome: outcome,
          outcome_reason: outcome_reason
        },
        nil
      )
  end
end
