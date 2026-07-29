defmodule Custode.CLIPauseTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]
  import Custode.TestHelpers

  alias Custode.CLI.Client
  alias Custode.{OperationCall, Repo}
  alias ObanClaude.Agent

  test "the live CLI-over-MCP contract records CLI as the trusted origin" do
    id = start_stub_agent!()
    key = "cli-#{System.unique_integer([:positive])}"
    arguments = %{agent_id: id, idempotency_key: key}

    assert {:ok, %{"agent_id" => ^id, "state" => "paused"}} =
             Client.call("pause_agent", arguments)

    assert {:ok, :paused} = Agent.await(id, :paused, 1_000)

    assert %OperationCall{
             operation: "fleet.pause_agent",
             actor: %{"kind" => "operator", "id" => "operator"},
             transport: "cli",
             status: "succeeded"
           } = Repo.get_by!(OperationCall, idempotency_key: key)

    assert {:ok, %{"agent_id" => ^id, "state" => "paused"}} =
             Client.call("pause_agent", arguments)

    assert Repo.aggregate(
             from(c in OperationCall, where: c.idempotency_key == ^key),
             :count
           ) == 1
  end
end
