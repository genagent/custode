defmodule Custode.SpendLedgerTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.SpendLedger
  alias ObanClaude.Agent

  setup do
    path = Path.join(System.tmp_dir!(), uid("spend-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)
    :ok
  end

  defp run!(agent_id, cost) do
    {:ok, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => agent_id}},
        query_fun: respond(result(result: "done", cost_usd: cost))
      )

    :ok
  end

  test "successful and failed runs both land in the ledger" do
    id = uid("spender")
    run!(id, 0.25)

    {{:cancel, :max_budget_exceeded}, _} =
      ObanClaude.run(%{"prompt" => "x"},
        job: %Oban.Job{meta: %{"agent_id" => id}},
        query_fun: fail(error(:max_budget_exceeded, reason: %{session_id: "s", cost_usd: 0.5}))
      )

    assert_in_delta SpendLedger.today(id), 0.75, 0.0001
    assert SpendLedger.fleet_today() >= 0.75
  end

  test "an unbudgeted agent never pauses" do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{daily_budget_usd: nil})
    stub_routine!(routine)

    run!(routine.id, 100.0)
    assert {:ok, :idle} = Agent.status(routine.id)
  end

  test "crossing the daily budget pauses the routine and records a feed entry" do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace, %{daily_budget_usd: 0.5})
    stub_routine!(routine)

    run!(routine.id, 0.3)
    assert {:ok, :idle} = Agent.status(routine.id)

    run!(routine.id, 0.3)
    assert {:ok, :paused} = Agent.await(routine.id, :paused, 1_000)

    assert [entry] = Custode.Feed.tail() |> Enum.filter(&(&1["event"] == "budget_paused"))
    assert entry["agent"] == routine.id
    assert entry["action"] =~ "daily budget hit"

    # resume is a human override; the next spend re-pauses
    :resumed = Agent.resume_agent(routine.id)
    run!(routine.id, 0.1)
    assert {:ok, :paused} = Agent.await(routine.id, :paused, 1_000)
  end

  test "a breach with the agent offline records spend but pauses nothing" do
    routine = routine_fixture!(tmp_workspace!(), %{daily_budget_usd: 0.1})
    run!(routine.id, 5.0)
    assert {:ok, :offline} = Agent.status(routine.id)
    assert_in_delta SpendLedger.today(routine.id), 5.0, 0.0001
  end

  defp stub_routine!(routine) do
    {:ok, _pid} = Agent.start_agent(routine.id, enqueue_fun: fn _a, _m -> {:ok, :queued} end)
    on_exit(fn -> Agent.stop_agent(routine.id) end)
    :ok
  end
end
