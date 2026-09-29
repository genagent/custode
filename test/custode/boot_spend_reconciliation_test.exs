defmodule Custode.BootSpendReconciliationTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{
    AgentHandoff,
    AgentHandoffIntent,
    Agents,
    InboxWake,
    InboxWakes,
    OperatorMessage,
    OperatorMessages,
    ProviderJobs,
    Repo,
    SpendLedger
  }

  test "cold boot cancels admitted turns and restores the spend rail before replay" do
    Repo.delete_all(OperatorMessage)
    Repo.delete_all(InboxWake)
    Repo.delete_all(AgentHandoffIntent)

    routine =
      routine_fixture!(tmp_workspace!(), %{
        provider: :claude,
        daily_budget_usd: 1.0
      })

    on_exit(fn -> Agents.stop_agent(routine.id, routine.provider) end)

    :ok = SpendLedger.record(routine.id, 2.0, "turn")

    assert {:ok, _wake} = InboxWakes.request(routine, debounce_seconds: 0)

    assert {:ok, queued_message, :created} =
             OperatorMessages.submit(routine.id, "run after restart", [], fn _message ->
               {:ok, :queued}
             end)

    assert {:ok, admitted_message, :created} =
             OperatorMessages.submit(routine.id, "admitted before restart", [], fn _message ->
               {:ok, :delivered}
             end)

    available =
      insert_provider_job!(routine.id, "available", %{
        "correlation_id" => admitted_message.provider_correlation_id
      })

    retryable = insert_provider_job!(routine.id, "retryable")

    on_exit(fn ->
      Enum.each([available, retryable], fn job ->
        if persisted = Repo.get(Oban.Job, job.id), do: Repo.delete!(persisted)
      end)
    end)

    assert :ok = Supervisor.terminate_child(Custode.Supervisor, AgentHandoff)
    assert Process.whereis(AgentHandoff) == nil

    on_exit(fn ->
      if Process.whereis(AgentHandoff) == nil do
        Supervisor.restart_child(Custode.Supervisor, AgentHandoff)
      end
    end)

    assert :ignore = InboxWakes.BootReconciler.start_link([])
    assert {:ok, :paused} = Agents.await(routine.id, routine.provider, :paused, 1_000)

    assert %{
             "cause" => "emergency_pause",
             "reason" => reason
           } = AgentHandoffIntent.get(routine.id)

    assert reason =~ "daily budget hit"
    assert %{state: "pending", blocked_by: "spend_rail"} = InboxWakes.get(routine.id)

    assert %{status: "queued", delivery: "queued"} =
             OperatorMessages.get(queued_message.message_id)

    assert %{status: "queued", delivery: "delivered"} =
             OperatorMessages.get(admitted_message.message_id)

    assert Repo.reload!(available).state == "cancelled"
    assert Repo.reload!(retryable).state == "cancelled"
    assert active_provider_jobs(routine.id) == []

    assert {:ok, handoff} = Supervisor.restart_child(Custode.Supervisor, AgentHandoff)
    assert is_pid(handoff)

    assert {:pending, %{phase: :preserved, preserve_pause?: true}} =
             AgentHandoff.status(routine.id)

    assert AgentHandoffIntent.get(routine.id) == nil

    assert %{status: "queued", delivery: "queued"} =
             OperatorMessages.get(queued_message.message_id)

    assert %{
             status: "failed",
             delivery: "delivered",
             prompt: "admitted before restart",
             error: %{"kind" => "recovered_job_state"}
           } = OperatorMessages.get(admitted_message.message_id)

    assert active_provider_jobs(routine.id) == []

    parent = self()

    assert :ignore =
             ProviderJobs.BootStarter.start_link(
               refresh_credentials: fn -> :ok end,
               start_agents_queue: fn ->
                 states =
                   Enum.map([available, retryable], fn job -> Repo.reload!(job).state end)

                 send(parent, {:agents_queue_opened, states})
                 :ok
               end
             )

    assert_receive {:agents_queue_opened, ["cancelled", "cancelled"]}
  end

  defp active_provider_jobs(agent_id), do: ProviderJobs.active_turns(agent_id)

  defp insert_provider_job!(agent_id, state, extra_meta \\ %{}) do
    meta =
      Map.merge(
        %{
          "agent_id" => agent_id,
          "agent_generation" => Ecto.UUID.generate(),
          "agent_turn_id" => Ecto.UUID.generate()
        },
        extra_meta
      )

    %{"prompt" => "must remain behind the spend rail"}
    |> Oban.Job.new(
      worker: ObanClaude.Agent.Job,
      queue: :agents,
      meta: meta
    )
    |> Ecto.Changeset.change(state: state)
    |> Repo.insert!()
  end
end
