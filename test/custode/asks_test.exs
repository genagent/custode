defmodule Custode.AsksTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Asks

  setup do
    # Asks contribute to the fleet-wide attention count, which the chip in
    # CustodeWeb.Components reads. Leaving rows behind inflates that count for
    # every later test and breaks assertions that have nothing to do with
    # asks, so this module cleans up after itself.
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine, workspace: workspace}
  end

  describe "ask/3" do
    test "files an open question", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "is the uncommitted diff yours?", detail: "on main")

      assert ask.status == "open"
      assert ask.question == "is the uncommitted diff yours?"
      assert ask.detail == "on main"
      assert ask.answer == nil
    end

    test "refuses an empty question", %{routine: routine} do
      assert {:error, _reason} = Asks.ask(routine.id, "   ")
    end

    test "does not dedupe: asking twice is itself information", %{routine: routine} do
      {:ok, first} = Asks.ask(routine.id, "same question")
      {:ok, second} = Asks.ask(routine.id, "same question")

      refute first.id == second.id
      assert length(Asks.open()) >= 2
    end
  end

  describe "open/0 and open_by_agent/0" do
    test "open asks come back oldest first", %{routine: routine} do
      {:ok, first} = Asks.ask(routine.id, "asked first")
      {:ok, second} = Asks.ask(routine.id, "asked second")

      ids = Asks.open() |> Enum.map(& &1.id)
      assert Enum.find_index(ids, &(&1 == first.id)) < Enum.find_index(ids, &(&1 == second.id))
    end

    test "grouped by agent, newest first within an agent", %{routine: routine} do
      {:ok, first} = Asks.ask(routine.id, "older")
      {:ok, second} = Asks.ask(routine.id, "newer")

      [head | _rest] = Asks.open_by_agent()[routine.id]
      assert head.id == second.id
      # the resolver takes List.last/1 to get the oldest, so assert the tail
      assert List.last(Asks.open_by_agent()[routine.id]).id == first.id
    end

    test "an answered ask leaves the open set", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "transient")
      {:ok, _answered} = Asks.answer(ask.id, "yes")

      refute Enum.any?(Asks.open(), &(&1.id == ask.id))
    end
  end

  describe "answer/2" do
    test "closes the ask and records the answer", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "which env?")
      {:ok, answered} = Asks.answer(ask.id, "staging")

      assert answered.status == "answered"
      assert answered.answer == "staging"
      assert %DateTime{} = answered.answered_at
    end

    test "delivers the answer to the agent's inbox, so its next sweep reads it",
         %{routine: routine, workspace: workspace} do
      {:ok, ask} = Asks.ask(routine.id, "which env?")
      {:ok, _answered} = Asks.answer(ask.id, "staging, and leave prod alone")

      note = Path.join([Path.expand(workspace), "inbox", "answer-#{ask.id}.md"])
      assert File.exists?(note)

      body = File.read!(note)
      assert body =~ "which env?"
      assert body =~ "staging, and leave prod alone"
    end

    test "refuses an unknown ask" do
      assert {:error, _reason} = Asks.answer(999_999, "hello")
    end

    test "refuses to answer twice", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "once")
      {:ok, _first} = Asks.answer(ask.id, "yes")

      assert {:error, reason} = Asks.answer(ask.id, "no, wait")
      assert reason =~ "already answered"
    end

    test "refuses an empty answer", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "something")
      assert {:error, _reason} = Asks.answer(ask.id, "  ")
    end

    test "an agent with no routine still gets its ask closed" do
      # a sub-agent or one-shot has no workspace and therefore no inbox;
      # losing the delivery must not block the operator from clearing it
      {:ok, ask} = Asks.ask("ephemeral-#{System.unique_integer([:positive])}", "orphan question")

      assert {:ok, answered} = Asks.answer(ask.id, "noted")
      assert answered.status == "answered"
    end
  end
end
