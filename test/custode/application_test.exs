defmodule Custode.ApplicationTest do
  use ExUnit.Case, async: true

  alias Custode.InboxWakes.BootReconciler, as: InboxWakesBootReconciler
  alias Custode.MCP.{BootConfigWriter, Identity, Probe}
  alias Custode.OperatorMessages.BootReconciler, as: OperatorMessagesBootReconciler
  alias Custode.ProviderJobs.BootStarter
  alias ObanClaude.Agent.Supervisor, as: ClaudeAgentSupervisor
  alias ObanCodex.Agent.Supervisor, as: CodexAgentSupervisor

  test "startup restores durable barriers and the listener before replaying work" do
    ids =
      Custode.Application.startup_children()
      |> Enum.map(&child_id/1)

    assert ordered?(ids, [
             OperatorMessagesBootReconciler,
             Oban,
             ClaudeAgentSupervisor,
             CodexAgentSupervisor,
             Identity,
             BootConfigWriter,
             InboxWakesBootReconciler,
             Bandit,
             Custode.AgentHandoff,
             BootStarter,
             Probe,
             Custode.Scheduler
           ])
  end

  test "startup restores spend authority before handoff replay and queue release" do
    ids =
      Custode.Application.startup_children()
      |> Enum.map(&child_id/1)

    assert ordered?(ids, [
             ClaudeAgentSupervisor,
             CodexAgentSupervisor,
             InboxWakesBootReconciler,
             Custode.AgentHandoff,
             BootStarter,
             Probe,
             Custode.Scheduler
           ])
  end

  test "provider execution queues stay withheld during initial Oban startup" do
    assert {Oban, opts} =
             Enum.find(Custode.Application.startup_children(), fn
               {Oban, _opts} -> true
               _child -> false
             end)

    queues = Keyword.fetch!(opts, :queues)

    refute Keyword.has_key?(queues, :agents)
    refute Keyword.has_key?(queues, :ticks)
  end

  test "one-shot startup barriers are temporary workers" do
    assert %{
             start: {OperatorMessagesBootReconciler, :start_link, [[]]},
             restart: :temporary,
             type: :worker
           } =
             OperatorMessagesBootReconciler.child_spec([])

    assert %{
             start: {BootConfigWriter, :start_link, [[]]},
             restart: :temporary,
             type: :worker
           } =
             BootConfigWriter.child_spec([])

    assert %{
             start: {BootStarter, :start_link, [[]]},
             restart: :temporary,
             type: :worker
           } =
             BootStarter.child_spec([])
  end

  test "provider boot refresh and queue open share the serialized configuration boundary" do
    parent = self()

    reconfigure = fn [], callback ->
      send(parent, :entered_configuration_boundary)
      result = callback.()
      send(parent, {:left_configuration_boundary, result})
      result
    end

    assert :ignore =
             BootStarter.start_link(
               reconfigure: reconfigure,
               reconcile_removed: fn ->
                 send(parent, :removed_routines_reconciled)
                 :ok
               end,
               reconcile_legacy: fn ->
                 send(parent, :legacy_turns_reconciled)
                 :ok
               end,
               refresh_credentials: fn ->
                 send(parent, :credentials_refreshed)
                 :ok
               end,
               start_agents_queue: fn ->
                 send(parent, :agents_queue_started)
                 :ok
               end
             )

    assert_receive :entered_configuration_boundary
    assert_receive :removed_routines_reconciled
    assert_receive :legacy_turns_reconciled
    assert_receive :credentials_refreshed
    assert_receive :agents_queue_started
    assert_receive {:left_configuration_boundary, {:ok, :agents_queue_started}}
  end

  test "provider boot fails before opening agents when the configuration boundary refuses" do
    assert_raise RuntimeError, ~r/could not open the agents queue/, fn ->
      BootStarter.start_link(
        reconfigure: fn [], _callback -> {:error, :not_ready} end,
        refresh_credentials: fn -> flunk("refresh must stay inside the boundary") end,
        start_agents_queue: fn -> flunk("queue must stay closed") end
      )
    end
  end

  defp ordered?(ids, expected) do
    positions = Map.new(Enum.with_index(ids))

    expected
    |> Enum.map(&Map.fetch!(positions, &1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.all?(fn [left, right] -> left < right end)
  end

  defp child_id(child) do
    case Supervisor.child_spec(child, []) do
      %{start: {Bandit, :start_link, _args}} -> Bandit
      %{id: id} -> id
    end
  end
end
