defmodule Custode.OperationCallsTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    OperationCall,
    OperationDispatcher,
    OperationRegistry,
    Repo
  }

  alias Custode.Operations.Fleet.PauseAgent

  setup do
    Repo.delete_all(OperationCall)
    :ok
  end

  test "a command requires a caller-stable idempotency key" do
    assert {:error, {:invalid_envelope, :idempotency_key}} = dispatch(definition(), key: nil)
    assert Repo.aggregate(OperationCall, :count) == 0
  end

  test "a terminal retry replays one result and one structured effect" do
    {:ok, effects} = Agent.start_link(fn -> 0 end)

    operation =
      definition(
        handler: fn arguments, _envelope ->
          Agent.update(effects, &(&1 + 1))

          {:ok, %{agent_id: arguments.agent_id, state: "paused"},
           [%{type: "agent_paused", agent_id: arguments.agent_id}]}
        end
      )

    assert {:ok, first} =
             dispatch(operation,
               key: "same",
               expected_versions: %{agent: 7},
               mission_id: "mission-1",
               work_item_id: "work-1",
               attempt_id: "attempt-1"
             )

    assert {:ok, replay} = dispatch(operation, key: "same", correlation_id: "replacement")

    assert first.call_id == replay.call_id
    assert first.replayed == false
    assert replay.replayed == true
    assert replay.result == %{agent_id: "target", state: "paused"}
    assert replay.effects == [%{type: "agent_paused", agent_id: "target"}]
    assert replay.correlation_id == "corr-original"
    assert replay.causation_id == "cause-original"
    assert Agent.get(effects, & &1) == 1
    assert Repo.aggregate(OperationCall, :count) == 1

    assert %OperationCall{
             expected_versions: %{"agent" => 7},
             effects: %{
               "items" => [%{"type" => "agent_paused", "agent_id" => "target"}]
             },
             mission_id: "mission-1",
             work_item_id: "work-1",
             attempt_id: "attempt-1"
           } = Repo.get_by!(OperationCall, idempotency_key: "same")
  end

  test "a duplicate call is authorized before an existing result is revealed" do
    operation =
      definition(
        handler: fn arguments, _envelope ->
          {:ok, %{agent_id: arguments.agent_id, state: "paused"}}
        end
      )

    assert {:ok, first} = dispatch(operation, key: "protected-result")

    assert {:error, {:denied, :operator_required}} =
             dispatch(operation,
               key: "protected-result",
               actor: %{kind: :sub_agent, id: "worker"}
             )

    assert %OperationCall{
             call_id: call_id,
             status: "succeeded",
             authorization_result: %{"decision" => "allowed"}
           } = Repo.get_by!(OperationCall, idempotency_key: "protected-result")

    assert call_id == first.call_id
  end

  test "two concurrent claims invoke one handler" do
    parent = self()
    {:ok, effects} = Agent.start_link(fn -> 0 end)

    operation =
      definition(
        handler: fn arguments, _envelope ->
          Agent.update(effects, &(&1 + 1))
          send(parent, :handler_entered)

          receive do
            :release -> :ok
          end

          {:ok, %{agent_id: arguments.agent_id, state: "paused"}}
        end
      )

    first = Task.async(fn -> dispatch(operation, key: "concurrent") end)
    assert_receive :handler_entered

    assert {:ok, duplicate} = dispatch(operation, key: "concurrent")
    assert duplicate.status in [:proposed, :running]
    assert duplicate.replayed

    send(first.pid, :release)
    assert {:ok, completed} = Task.await(first)
    assert completed.status == :succeeded
    assert completed.call_id == duplicate.call_id
    assert Agent.get(effects, & &1) == 1
    assert Repo.aggregate(OperationCall, :count) == 1
  end

  test "denied and stale calls retain their decision and perform no effect" do
    parent = self()
    handler = fn _arguments, _envelope -> send(parent, :effect) end
    denied = definition(handler: handler)

    assert {:error, {:denied, :operator_required}} =
             dispatch(denied, key: "denied", actor: %{kind: :sub_agent, id: "worker"})

    assert %OperationCall{
             status: "denied",
             authorization_result: %{"decision" => "denied"}
           } = Repo.get_by!(OperationCall, idempotency_key: "denied")

    stale =
      definition(
        handler: handler,
        precondition: fn _arguments, _envelope ->
          {:stale, :version_changed, %{expected: 2, observed: 3}}
        end
      )

    assert {:error, {:stale, :version_changed}} = dispatch(stale, key: "stale")

    assert %OperationCall{
             status: "stale",
             preconditions: %{"expected" => 2, "observed" => 3}
           } = Repo.get_by!(OperationCall, idempotency_key: "stale")

    refute_received :effect
  end

  test "a stale result detected atomically by a handler is recorded as stale" do
    operation =
      definition(
        handler: fn _arguments, _envelope ->
          {:error, {:stale, :version_changed, %{work_item: %{expected: 2, observed: 3}}}}
        end
      )

    assert {:error, {:stale, :version_changed}} =
             dispatch(operation, key: "atomic-stale")

    assert %OperationCall{
             status: "stale",
             preconditions: %{
               "work_item" => %{"expected" => 2, "observed" => 3}
             }
           } = Repo.get_by!(OperationCall, idempotency_key: "atomic-stale")
  end

  test "dry runs are durable previews and never invoke the handler" do
    parent = self()
    operation = definition(handler: fn _, _ -> send(parent, :effect) end)

    assert {:ok, response} = dispatch(operation, key: "preview", dry_run: true)
    assert response.status == :dry_run
    assert response.effect_preview == %{effect: "pause_agent", agent_id: "target"}
    refute_received :effect

    assert %OperationCall{status: "succeeded", dry_run: true, result: nil} =
             Repo.get_by!(OperationCall, idempotency_key: "preview")
  end

  test "handler failures are recorded and replayed without another attempt" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    operation =
      definition(
        handler: fn _arguments, _envelope ->
          Agent.update(attempts, &(&1 + 1))
          {:error, :offline}
        end
      )

    assert {:error, {:handler_failed, :offline}} = dispatch(operation, key: "failure")
    assert {:error, {:handler_failed, "offline"}} = dispatch(operation, key: "failure")
    assert Agent.get(attempts, & &1) == 1

    assert %OperationCall{status: "failed", error: %{"kind" => "handler_failed"}} =
             Repo.get_by!(OperationCall, idempotency_key: "failure")
  end

  test "an expired physical delivery reconciles an effect before retrying" do
    {:ok, effects} = Agent.start_link(fn -> 0 end)

    operation =
      definition(
        handler: fn _arguments, _envelope ->
          Agent.update(effects, &(&1 + 1))
          exit(:crashed_after_effect)
        end,
        reconcile: fn call ->
          if Agent.get(effects, & &1) == 1 do
            {:ok, %{agent_id: call.arguments["agent_id"], state: "paused"},
             [%{type: "agent_paused", agent_id: call.arguments["agent_id"]}]}
          else
            :retry
          end
        end
      )

    {pid, ref} = spawn_monitor(fn -> dispatch(operation, key: "recover") end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :crashed_after_effect}

    expire_lease!("recover")

    assert {:ok, recovered} = dispatch(operation, key: "recover")
    assert recovered.status == :succeeded
    assert recovered.replayed
    assert Agent.get(effects, & &1) == 1
  end

  test "an expired delivery before an effect is safely retryable" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)
    {:ok, effects} = Agent.start_link(fn -> 0 end)

    operation =
      definition(
        handler: fn arguments, _envelope ->
          case Agent.get_and_update(attempts, fn count -> {count, count + 1} end) do
            0 ->
              exit(:crashed_before_effect)

            _retry ->
              Agent.update(effects, &(&1 + 1))
              {:ok, %{agent_id: arguments.agent_id, state: "paused"}}
          end
        end,
        reconcile: fn _call ->
          if Agent.get(effects, & &1) == 0, do: :retry, else: {:waiting, :unexpected}
        end
      )

    {pid, ref} = spawn_monitor(fn -> dispatch(operation, key: "retry") end)
    assert_receive {:DOWN, ^ref, :process, ^pid, :crashed_before_effect}

    expire_lease!("retry")

    assert {:ok, response} = dispatch(operation, key: "retry")
    assert response.status == :succeeded
    assert Agent.get(attempts, & &1) == 2
    assert Agent.get(effects, & &1) == 1
  end

  test "query definitions dispatch without an OperationCall row" do
    query =
      definition(
        classification: :query,
        risk: :read,
        handler: fn arguments, _envelope ->
          {:ok, %{agent_id: arguments.agent_id, state: "visible"}}
        end
      )

    assert {:ok, %{status: :succeeded, result: %{state: "visible"}}} =
             dispatch(query, key: nil)

    assert Repo.aggregate(OperationCall, :count) == 0
  end

  defp dispatch(operation, options) do
    {:ok, registry} = OperationRegistry.new([operation])

    attrs = %{
      operation: operation.name,
      arguments: %{agent_id: "target"},
      actor: Keyword.get(options, :actor, %{kind: :operator, id: "human"}),
      transport: :worker,
      idempotency_key: options[:key],
      expected_versions: options[:expected_versions],
      correlation_id: Keyword.get(options, :correlation_id, "corr-original"),
      causation_id: "cause-original",
      mission_id: options[:mission_id],
      work_item_id: options[:work_item_id],
      attempt_id: options[:attempt_id],
      dry_run: Keyword.get(options, :dry_run, false)
    }

    OperationDispatcher.dispatch(attrs, registry)
  end

  defp definition(overrides \\ []) do
    PauseAgent.definition()
    |> struct!(overrides)
  end

  defp expire_lease!(key) do
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Repo.update_all(
      from(c in OperationCall, where: c.idempotency_key == ^key),
      set: [lease_expires_at: past]
    )
  end
end
