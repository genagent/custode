defmodule Custode.Operator.BootstrapTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Installation
  alias Custode.MCP.{Identity, ToolPolicy}
  alias Custode.Operator.Bootstrap

  @operator %{kind: :operator, id: "operator"}

  setup do
    clear_attention!()
    :ok
  end

  test "build/2 summarizes the installation, caller, authority and fleet" do
    result = Bootstrap.build(@operator)

    assert result.schema_version == "custode.operator_bootstrap.v1"
    assert result.schema_version == Bootstrap.schema_version()

    assert result.installation.id == Installation.id()
    assert is_binary(result.installation.custode_version)

    assert %{kind: "operator", id: "operator", transport: "mcp", verified: true} = result.caller
    assert %{scope: "all", endpoint: "main", tool_count: tool_count} = result.authority
    assert tool_count == map_size(ToolPolicy.all())

    assert result.fleet |> Map.keys() |> Enum.sort() ==
             [:attention, :caretaker, :executing_turns, :open_asks, :open_gates, :routines]

    assert is_integer(result.fleet.routines.total)
    assert is_integer(result.fleet.executing_turns)
    assert is_integer(result.fleet.attention.total)
    assert is_integer(result.fleet.open_gates)
    assert is_integer(result.fleet.open_asks)
  end

  test "build/2 stamps the transport and verification it is given" do
    result = Bootstrap.build(@operator, transport: :cli, verified: false)

    assert %{transport: "cli", verified: false} = result.caller
  end

  test "every expand entry names a tool in the policy table" do
    %{expand: expand} = Bootstrap.build(@operator)
    policy = ToolPolicy.all()

    assert expand != []

    for %{topic: topic, tool: tool} <- expand do
      assert is_binary(topic)
      assert Map.has_key?(policy, tool), "#{tool} is not in Custode.MCP.ToolPolicy.all/0"
    end
  end

  test "the caretaker is the routine tagged :meta" do
    workspace = tmp_workspace!()
    caretaker_id = uid("caretaker")
    other_id = uid("other")

    put_env!(:routines, [
      %{id: other_id, cron: :manual, workspace: workspace, prompt: "x"},
      %{id: caretaker_id, cron: :manual, workspace: workspace, prompt: "x", tags: [:meta]}
    ])

    assert %{id: ^caretaker_id, state: state} = Bootstrap.build(@operator).fleet.caretaker
    assert is_atom(state)
  end

  test "there is no caretaker when no routine is tagged :meta" do
    put_env!(:routines, [
      %{id: uid("plain"), cron: :manual, workspace: tmp_workspace!(), prompt: "x"}
    ])

    assert Bootstrap.build(@operator).fleet.caretaker == nil
  end

  test "the result holds no database path, installation file or operator token" do
    {:ok, operator_token} = Identity.operator_token()
    database = :custode |> Application.get_env(Custode.Repo) |> Keyword.fetch!(:database)

    encoded = @operator |> Bootstrap.build() |> Jason.encode!()

    refute encoded =~ Path.expand(database)
    refute encoded =~ database
    refute encoded =~ ".installation"
    refute encoded =~ operator_token
  end
end
