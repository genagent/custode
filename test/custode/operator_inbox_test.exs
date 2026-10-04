defmodule Custode.Operator.InboxTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Asks
  alias Custode.Attention.Fleet
  alias Custode.Operator.Inbox

  setup do
    # Asks contribute to the fleet-wide attention count, which the chip in
    # CustodeWeb.Components reads. Leaving rows behind inflates that count for
    # every later test and breaks assertions that have nothing to do with
    # asks, so this module cleans up after itself.
    on_exit(fn -> Custode.Repo.query!("DELETE FROM asks") end)
    path = Path.join(System.tmp_dir!(), uid("inbox") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{routine: routine}
  end

  describe "items/0" do
    test "an open ask arrives as a question, carrying its answer action", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "is the uncommitted diff yours?")

      item = Enum.find(Inbox.items(), &(&1.subject == routine.id))

      assert item.kind == :needs_answer
      assert item.headline == "asked you a question"
      assert item.detail == "is the uncommitted diff yours?"
      # Straight off the signal's resolving list: a new kind gets working
      # buttons here with no template change.
      assert Enum.any?(item.actions, &(&1.op == :answer_ask and &1.args.ask == ask.id))
    end

    test "an answered ask leaves the inbox", %{routine: routine} do
      {:ok, ask} = Asks.ask(routine.id, "transient")
      assert Enum.any?(Inbox.items(), &(&1.subject == routine.id))

      {:ok, _answered} = Asks.answer(ask.id, "yes")
      refute Enum.any?(Inbox.items(), &(&1.subject == routine.id))
    end

    test "an agent that has raised nothing does not appear", %{routine: routine} do
      # offline with a cron is how a cold-start routine RESTS; it has asked
      # for nothing, so it owes the operator nothing. Asserted about THIS
      # agent rather than about an empty list, because the suite shares a
      # registry and another test's agent may legitimately be in here.
      refute Enum.any?(Inbox.items(), &(&1.subject == routine.id))
    end

    test "advisor suggestions arrive with apply and dismiss", %{routine: routine} do
      Custode.Feed.record(%{
        event: "advisor_suggestion",
        agent: routine.id,
        advisor: "advisor-cadence",
        field: "cron",
        current: "@daily",
        proposed: "*/30 9-18 * * *",
        evidence: "9 of 6 daily sweeps yielded"
      })

      item = Enum.find(Inbox.items(), &(&1.kind == :suggestion))

      assert item.subject == "advisor-cadence"
      assert item.headline =~ "@daily -> */30 9-18 * * *"
      assert item.detail == "9 of 6 daily sweeps yielded"
      assert Enum.map(item.actions, & &1.op) == [:apply_suggestion, :dismiss_suggestion]
    end

    test "a suggestion on an unappliable field offers dismiss only", %{routine: routine} do
      Custode.Feed.record(%{
        event: "advisor_suggestion",
        agent: routine.id,
        advisor: "advisor-model",
        field: "something_unappliable",
        current: "a",
        proposed: "b"
      })

      item = Enum.find(Inbox.items(), &(&1.kind == :suggestion))
      assert Enum.map(item.actions, & &1.op) == [:dismiss_suggestion]
    end

    # The exclusion that design/007's group split implies. If this ever needs
    # relaxing, that is evidence the split was wrong.
    test "a red check does NOT appear: the fleet will look at it on its next beat" do
      refute Enum.any?(Inbox.items(), &(&1.kind == :red_check))
    end
  end

  test "items/1 projects the supplied snapshot instead of resolving the newer fleet", %{
    routine: routine
  } do
    {:ok, first} = Asks.ask(routine.id, "first")
    snapshot = Fleet.signals()
    {:ok, _dismissed} = Asks.dismiss(first.id)
    {:ok, second} = Asks.ask(routine.id, "second")

    old = Enum.find(Inbox.items(snapshot), &(&1.subject == routine.id))
    current = Enum.find(Inbox.items(), &(&1.subject == routine.id))
    assert old.detail == "first"
    assert current.detail == "second"
    assert Enum.any?(old.actions, &(&1.op == :answer_ask and &1.args.ask == first.id))
    assert Enum.any?(current.actions, &(&1.op == :answer_ask and &1.args.ask == second.id))
  end

  describe "unread/2 -- the pure half" do
    defp item(at), do: %Inbox.Item{kind: :needs_answer, subject: "a", headline: "h", at: at}

    test "a nil read-mark means everything is new" do
      items = [item(~U[2026-07-26 01:00:00Z])]
      assert Inbox.unread(items, nil) == items
    end

    test "keeps what came after and drops what came before" do
      before = item(~U[2026-07-26 01:00:00Z])
      later = item(~U[2026-07-26 03:00:00Z])

      assert Inbox.unread([before, later], ~U[2026-07-26 02:00:00Z]) == [later]
    end

    test "an undateable item always counts as unread" do
      # a signal the overview cache cannot date is better surfaced once too
      # often than silently aged out of the list the operator has to trust
      undateable = item(nil)
      assert Inbox.unread([undateable], ~U[2026-07-26 02:00:00Z]) == [undateable]
    end
  end

  describe "read state" do
    test "mark_read/0 records a timestamp that last_read_at/0 reads back" do
      assert :ok = Inbox.mark_read()
      assert %DateTime{} = first = Inbox.last_read_at()

      assert :ok = Inbox.mark_read()
      assert DateTime.compare(Inbox.last_read_at(), first) in [:gt, :eq]
    end

    test "an ask raised after the read mark is unread; one before it is not",
         %{routine: routine} do
      {:ok, _old} = Asks.ask(routine.id, "asked before the operator looked")
      :ok = Inbox.mark_read()
      read_at = Inbox.last_read_at()

      later = "later-agent-#{System.unique_integer([:positive])}"
      {:ok, _new} = Asks.ask(later, "asked after")

      unread = Inbox.since(read_at) |> Enum.map(& &1.subject)

      assert later in unread
      refute routine.id in unread
      # both are still IN the inbox; only their unread state differs
      subjects = Inbox.items() |> Enum.map(& &1.subject)
      assert routine.id in subjects and later in subjects
    end
  end
end
