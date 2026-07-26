defmodule Custode.AskToolsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Asks
  alias Custode.MCP.AskTools

  @operator %Anubis.Server.Frame{}

  defp routine_frame(id),
    do: %Anubis.Server.Frame{assigns: %{custode_identity: %{kind: :routine, id: id}}}

  setup do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine, workspace: workspace}
  end

  describe "ask_operator" do
    test "a routine files its own question and is told it is not blocked", %{routine: routine} do
      json =
        AskTools.AskOperator.execute(
          %{question: "is the uncommitted diff yours?"},
          routine_frame(routine.id)
        )
        |> tool_json()

      assert json["status"] == "open"
      assert json["note"] =~ "not blocked"

      ask = Asks.get(json["ask_id"])
      assert ask.agent_id == routine.id
      assert ask.question == "is the uncommitted diff yours?"
    end

    test "the caller's identity is the default author", %{routine: routine} do
      json =
        AskTools.AskOperator.execute(%{question: "whose am I?"}, routine_frame(routine.id))
        |> tool_json()

      assert Asks.get(json["ask_id"]).agent_id == routine.id
    end

    test "a routine may not file a question in another agent's name", %{routine: routine} do
      error =
        AskTools.AskOperator.execute(
          %{question: "not mine to ask", agent_id: "someone-else"},
          routine_frame(routine.id)
        )
        |> tool_error()

      assert error =~ "identity"
      refute Enum.any?(Asks.open(), &(&1.agent_id == "someone-else"))
    end

    test "an empty question is refused", %{routine: routine} do
      error =
        AskTools.AskOperator.execute(%{question: "   "}, routine_frame(routine.id))
        |> tool_error()

      assert error =~ "needs text"
    end
  end

  describe "list_asks" do
    test "returns open questions, and filters by agent", %{routine: routine} do
      other = "another-agent-#{System.unique_integer([:positive])}"
      {:ok, _ask} = Asks.ask(routine.id, "mine")
      {:ok, _other} = Asks.ask(other, "theirs")

      # the suite shares one db across tests, so assert on membership rather
      # than on the size of the whole open set
      all = AskTools.ListAsks.execute(%{}, @operator) |> tool_json()
      agents = Enum.map(all["asks"], & &1["agent_id"])
      assert routine.id in agents
      assert other in agents

      mine = AskTools.ListAsks.execute(%{agent_id: routine.id}, @operator) |> tool_json()
      assert [%{"question" => "mine"}] = mine["asks"]
    end
  end

  describe "answer_ask" do
    test "the operator answers and the agent is told", %{routine: routine, workspace: workspace} do
      {:ok, ask} = Asks.ask(routine.id, "which env?")

      json =
        AskTools.AnswerAsk.execute(%{ask_id: ask.id, answer: "staging"}, @operator)
        |> tool_json()

      assert json["status"] == "answered"
      assert json["agent_id"] == routine.id
      assert File.exists?(Path.join([Path.expand(workspace), "inbox", "answer-#{ask.id}.md"]))
    end

    # The load-bearing guarantee: agents operate the machine, humans judge the
    # work. An agent answering a question addressed to the operator would be
    # answering ON the operator's behalf, which is the one thing the gate
    # discipline exists to prevent.
    test "an agent may NOT answer the operator's questions", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "which env?")

      error =
        AskTools.AnswerAsk.execute(
          %{ask_id: ask.id, answer: "I'll decide myself"},
          routine_frame(routine.id)
        )
        |> tool_error()

      assert error =~ "identity"
      assert Asks.get(ask.id).status == "open"
    end

    test "an unknown ask is a tool error, not a crash" do
      error =
        AskTools.AnswerAsk.execute(%{ask_id: 999_999, answer: "hi"}, @operator)
        |> tool_error()

      assert error =~ "no ask"
    end
  end
end
