defmodule Custode.Attention.TurnFailingTest do
  @moduledoc """
  The gatherer's half of #527: a run that fails, end to end, from the engine's
  exception telemetry to the agent's resolved signal.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Attention.Fleet

  setup do
    %{routine: routine_fixture!(tmp_workspace!())}
  end

  defp run!(agent_id, query_fun) do
    ObanClaude.run(%{"prompt" => "x"},
      job: %Oban.Job{meta: %{"agent_id" => agent_id}},
      query_fun: query_fun
    )
  end

  defp fail!(agent_id, kind, opts \\ []), do: run!(agent_id, fail(error(kind, opts)))

  defp succeed!(agent_id),
    do: run!(agent_id, respond(structured_result(%{"directive" => "none", "summary" => "ok"})))

  defp signal(agent_id), do: Map.fetch!(Fleet.signals_by_id(), agent_id)

  test "a logged-out claude raises needs-you on the first failed turn", %{routine: routine} do
    fail!(routine.id, :auth, reason: :not_authenticated, message: "not logged in")

    raised = signal(routine.id)

    assert raised.kind == :turn_failing
    assert raised.group == :needs_you
    assert raised.headline =~ "claude is not logged in on this host"
    assert raised.detail =~ "not logged in"
    assert %DateTime{} = raised.raised_at
  end

  test "a successful turn since clears it", %{routine: routine} do
    fail!(routine.id, :auth, reason: :expired)
    assert signal(routine.id).kind == :turn_failing

    succeed!(routine.id)
    refute signal(routine.id).kind == :turn_failing
  end

  test "a retryable failure raises nothing, however often", %{routine: routine} do
    for _ <- 1..3, do: fail!(routine.id, :timeout)

    refute signal(routine.id).kind == :turn_failing
  end

  test "a retryable failure after a terminal one is the latest word", %{routine: routine} do
    fail!(routine.id, :auth, reason: :expired)
    fail!(routine.id, :timeout)

    refute signal(routine.id).kind == :turn_failing
  end

  test "a refused cap waits for the second in a row, and counts the run", %{routine: routine} do
    fail!(routine.id, :max_turns_exceeded)
    refute signal(routine.id).kind == :turn_failing

    fail!(routine.id, :max_turns_exceeded)
    raised = signal(routine.id)

    assert raised.kind == :turn_failing
    assert raised.detail =~ "2 failed turns (capability_refused)"
  end

  test "a turn_failed entry that is not a turn neither starts nor breaks the run",
       %{routine: routine} do
    fail!(routine.id, :auth, reason: :expired)

    Custode.Feed.record(%{event: "turn_failed", agent: routine.id, kind: "drain_timeout"})

    assert signal(routine.id).kind == :turn_failing
  end
end
