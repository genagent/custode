defmodule Custode.CLIDismissTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Custode.TestHelpers

  alias Custode.Asks
  alias Custode.CLI.Dismiss

  setup do
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine, workspace: workspace}
  end

  test "the command parses an integer ask id and an optional reason" do
    assert {:ok, Dismiss, %{ask_id: 42, reason: "already handled"}} =
             Cheer.parse(Mix.Tasks.Custode, ["dismiss", "42", "already handled"])

    assert {:ok, Dismiss, args} = Cheer.parse(Mix.Tasks.Custode, ["dismiss", "42"])
    assert args.ask_id == 42
    assert is_nil(args[:reason])
  end

  test "a missing ask id is a usage error" do
    capture_io(fn ->
      assert {:error, :usage} = Cheer.parse(Mix.Tasks.Custode, ["dismiss"])
    end)
  end

  test "an invalid ask id is rejected before calling the MCP transport" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, :run_failed} =
                 Cheer.run(Mix.Tasks.Custode, ["dismiss", "not-an-id"])
      end)

    assert output =~ "ask id must be an integer"
  end

  test "the parsed command dismisses through the live MCP transport", %{
    routine: routine,
    workspace: workspace
  } do
    {:ok, ask} = Asks.ask(routine.id, "is SAML fixed?")

    output =
      capture_io(fn ->
        assert :ok =
                 Cheer.run(Mix.Tasks.Custode, ["dismiss", to_string(ask.id), "already resolved"])
      end)

    assert output =~ "ask #{ask.id} dismissed; no answer sent"
    assert Asks.get(ask.id).status == "dismissed"
    assert Asks.get(ask.id).dismissal_reason == "already resolved"
    refute File.exists?(Path.join([Path.expand(workspace), "inbox", "answer-#{ask.id}.md"]))
  end

  test "the command sends an omitted reason through the live MCP transport", %{routine: routine} do
    {:ok, ask} = Asks.ask(routine.id, "is this still relevant?")

    capture_io(fn ->
      assert :ok = Cheer.run(Mix.Tasks.Custode, ["dismiss", to_string(ask.id)])
    end)

    assert Asks.get(ask.id).status == "dismissed"
    assert is_nil(Asks.get(ask.id).dismissal_reason)
  end

  test "a tool failure returns a command failure" do
    output =
      capture_io(:stderr, fn ->
        assert {:error, :run_failed} = Dismiss.run(%{ask_id: -1}, [])
      end)

    assert output =~ "no ask"
  end
end
