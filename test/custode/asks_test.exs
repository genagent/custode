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

  describe "the feed trail (#445)" do
    test "filing an ask records an asked entry against the asking agent", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "is the uncommitted diff yours?", detail: "on main")

      assert [entry] = feed_events(routine.id, "asked")
      assert entry["ask_id"] == ask.id
      assert entry["question"] == "is the uncommitted diff yours?"
      assert entry["summary"] =~ "is the uncommitted diff yours?"
    end

    test "a refused ask records nothing, because nothing was asked", %{routine: routine} do
      assert {:error, _reason} = Asks.ask(routine.id, "   ")
      assert feed_events(routine.id, "asked") == []
    end

    test "answering records the matching answered entry, so the pair reads back",
         %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "which env?")
      {:ok, _answered} = Asks.answer(ask.id, "staging")

      assert [asked] = feed_events(routine.id, "asked")
      assert [answered] = feed_events(routine.id, "answered")
      assert answered["ask_id"] == asked["ask_id"]
      assert answered["question"] == "which env?"
      assert answered["answer"] == "staging"
    end

    test "a refused answer records nothing", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "once")
      {:ok, _first} = Asks.answer(ask.id, "yes")
      assert {:error, _reason} = Asks.answer(ask.id, "no, wait")

      assert [_only] = feed_events(routine.id, "answered")
    end

    test "an ask reaches ntfy at the quiet weight, below a blocking gate", %{routine: routine} do
      test_pid = self()
      put_env!(:ntfy_sink, fn message -> send(test_pid, {:ntfy, message}) end)
      put_env!(:ntfy, topic: "custode-test", publish: :all)
      title = "#{routine.id} asked"

      {:ok, _ask} = Asks.ask(routine.id, "may I carry on?")

      assert_receive {:ntfy, %{title: ^title} = message}, 500
      assert message.priority == 1
      assert message.body =~ "may I carry on?"
    end

    test "with ntfy narrowed to attention events, an ask does not ring the phone",
         %{routine: routine} do
      test_pid = self()
      put_env!(:ntfy_sink, fn message -> send(test_pid, {:ntfy, message}) end)
      put_env!(:ntfy, topic: "custode-test", publish: :attention)
      title = "#{routine.id} asked"

      {:ok, _ask} = Asks.ask(routine.id, "may I carry on?")

      refute_receive {:ntfy, %{title: ^title}}, 100
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

  describe "dismiss/2" do
    test "retains a reason and time without an answer, inbox note, or wake",
         %{routine: routine, workspace: workspace} do
      {:ok, ask} = Asks.ask(routine.id, "authorize SAML?")
      inbox = Path.wildcard(Path.join([workspace, "inbox", "*"]))
      jobs = Custode.Repo.aggregate(Oban.Job, :count)

      assert {:ok, dismissed} = Asks.dismiss(ask.id, "  already fixed  ")
      assert dismissed.status == "dismissed"
      assert dismissed.dismissal_reason == "already fixed"
      assert %DateTime{} = dismissed.dismissed_at
      assert dismissed.answer == nil
      assert dismissed.answered_at == nil
      assert Asks.get(ask.id) == dismissed
      assert Path.wildcard(Path.join([workspace, "inbox", "*"])) == inbox
      assert Custode.Repo.aggregate(Oban.Job, :count) == jobs
      refute Enum.any?(Asks.open(), &(&1.id == ask.id))
      refute Map.has_key?(Asks.open_by_agent(), routine.id)

      assert [event] = feed_events(routine.id, "dismissed")
      assert event["ask_id"] == ask.id
      assert event["question"] == ask.question
      assert event["reason"] == "already fixed"
      assert event["summary"] =~ "already fixed"
      assert feed_events(routine.id, "answered") == []
      assert feed_events(routine.id, "inbox_note") == []
    end

    test "a reason is optional and blank reasons become nil", %{routine: routine} do
      for reason <- [nil, "   "] do
        {:ok, ask} = Asks.ask(routine.id, "obsolete")
        assert {:ok, dismissed} = Asks.dismiss(ask.id, reason)
        assert dismissed.dismissal_reason == nil
      end
    end

    test "dismissal cannot be repeated or answered afterward", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "obsolete")
      {:ok, dismissed} = Asks.dismiss(ask.id, "resolved elsewhere")

      assert {:error, "ask " <> _rest} = Asks.dismiss(ask.id, "overwrite")
      assert {:error, reason} = Asks.answer(ask.id, "wake up")
      assert reason =~ "already dismissed"
      assert Asks.get(ask.id) == dismissed
      assert [_event] = feed_events(routine.id, "dismissed")
      assert feed_events(routine.id, "answered") == []
      assert feed_events(routine.id, "inbox_note") == []
    end

    test "an answer cannot be overwritten by dismissal", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "which environment?")
      {:ok, answered} = Asks.answer(ask.id, "staging")

      assert {:error, reason} = Asks.dismiss(ask.id, "obsolete")
      assert reason =~ "already answered"
      assert Asks.get(ask.id) == answered
      assert feed_events(routine.id, "dismissed") == []
    end

    test "unknown ids are refused without a feed entry", %{routine: routine} do
      assert {:error, "no ask -1"} = Asks.dismiss(-1)
      assert feed_events(routine.id, "dismissed") == []
    end

    test "dismissal frees a slot under the unanswered ask cap", %{routine: routine} do
      {:ok, first} = Asks.ask(routine.id, "obsolete")
      {:ok, _second} = Asks.ask(routine.id, "still relevant")
      assert {:error, _reason} = Asks.ask(routine.id, "new question")

      assert {:ok, _dismissed} = Asks.dismiss(first.id)
      assert {:ok, _new} = Asks.ask(routine.id, "new question")
    end

    test "competing answers and dismissals produce exactly one terminal event",
         %{routine: routine, workspace: workspace} do
      {:ok, ask} = Asks.ask(routine.id, "which environment?")

      tasks =
        for action <- [fn -> Asks.answer(ask.id, "staging") end, fn -> Asks.dismiss(ask.id) end] do
          Task.async(fn ->
            receive do
              :close -> action.()
            end
          end)
        end

      Enum.each(tasks, &send(&1.pid, :close))
      results = Enum.map(tasks, &Task.await/1)
      assert Enum.count(results, &match?({:ok, _ask}, &1)) == 1
      assert Enum.count(results, &match?({:error, _reason}, &1)) == 1

      closed = Asks.get(ask.id)
      events = feed_events(routine.id, "answered") ++ feed_events(routine.id, "dismissed")
      assert [event] = events
      assert event["event"] == closed.status
      delivered? = File.exists?(Path.join([workspace, "inbox", "answer-#{ask.id}.md"]))
      assert delivered? == (closed.status == "answered")
    end
  end

  # The feed table is shared by the whole suite, so every read here is scoped
  # to this test's own routine id.
  defp feed_events(agent_id, event) do
    agent_id |> Custode.Feed.for_agent(50) |> Enum.filter(&(&1["event"] == event))
  end

  # seen on the live fleet 2026-09-20/21: redisctl filed the same SAML question
  # eight times, once a sweep, worded a little differently each time
  describe "an agent's unanswered questions are capped" do
    test "past the cap a new ask is refused, naming what is already open" do
      id = uid("asker")
      {:ok, first} = Asks.ask(id, "GitHub reads return 403 (SAML). Can you authorize the token?")
      {:ok, _second} = Asks.ask(id, "Separately: is the uncommitted diff yours?")

      assert {:error, message} = Asks.ask(id, "GitHub still returns 403, please authorize")
      assert message =~ "you already have 2 unanswered question(s)"
      assert message =~ "##{first.id}"
      assert message =~ "GitHub reads return 403"
      assert length(Asks.open_by_agent()[id]) == 2
    end

    test "an answer makes room, and the cap is per agent" do
      id = uid("asker")
      {:ok, first} = Asks.ask(id, "one?")
      {:ok, _second} = Asks.ask(id, "two?")
      assert {:error, _full} = Asks.ask(id, "three?")

      # someone else's questions are their own
      assert {:ok, _other} = Asks.ask(uid("other"), "mine?")

      {:ok, _answered} = Asks.answer(first.id, "yes")
      assert {:ok, _third} = Asks.ask(id, "three?")
    end

    test "the cap is configurable" do
      put_env!(:max_open_asks, 1)
      id = uid("asker")
      {:ok, _first} = Asks.ask(id, "one?")
      assert {:error, _full} = Asks.ask(id, "two?")
    end
  end
end
