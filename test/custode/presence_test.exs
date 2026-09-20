defmodule Custode.PresenceTest do
  # Operator presence (#141 slice 1): inference from gate touches and
  # operator-origin turns, explicit override, and the tick-context render.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Presence

  setup do
    path = Path.join(System.tmp_dir!(), uid("presence-feed") <> ".jsonl")
    put_env!(:feed_path, path)
    previous = Application.get_env(:custode, :presence_override)

    on_exit(fn ->
      File.rm(path)
      Application.put_env(:custode, :presence_override, previous)
    end)

    Application.delete_env(:custode, :presence_override)
    :ok
  end

  test "an operator-origin answered turn flips presence to present" do
    # a fresh window with no operator evidence reads away only if nothing
    # else in the shared test db counts; anchor the assertion on the DELTA
    {_status_before, last_before} = Presence.status()

    answer = "here is the tradeoff analysis"

    {:ok, _} =
      ObanClaude.run(%{"prompt" => "thoughts?"},
        job: %Oban.Job{meta: %{"agent_id" => uid("pres"), "origin" => "operator"}},
        query_fun: ObanClaude.Testing.respond(ObanClaude.Testing.result(result: answer))
      )

    {status, last} = Presence.status()
    assert status == :present
    assert last != nil
    assert last_before == nil or DateTime.compare(last, last_before) in [:gt, :eq]
  end

  test "an explicit pin wins over inference in both directions" do
    # evaluate NOW as if it were far in the future, so no recorded action is
    # inside the window and only the pin can be deciding the answer
    future = DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)

    Application.put_env(:custode, :presence_override, :present)
    assert {:present, _} = Presence.status(future)

    Application.put_env(:custode, :presence_override, :away)
    assert {:away, _} = Presence.status()
  end

  test "a present pin lapses with the window; an away pin does not (#328)" do
    now = DateTime.utc_now()
    stale = DateTime.add(now, -46 * 60, :second)
    fresh = DateTime.add(now, -5 * 60, :second)

    # the failure this fixes: pin present, walk away, and every sweep all
    # night is told a human is around. Once lapsed the pin stops deciding
    # anything and the reading falls back to evidence.
    Application.put_env(:custode, :presence_override, {:present, stale})
    {_state, _at, why} = Presence.explain(now)
    refute why == {:pinned, :present}

    Application.put_env(:custode, :presence_override, {:present, fresh})
    assert {:present, _at, {:pinned, :present}} = Presence.explain(now)

    # away is intent, not a keystroke, so the clock never revokes it
    Application.put_env(:custode, :presence_override, :away)
    assert {:away, _at} = Presence.status(DateTime.add(now, 30 * 24 * 3600, :second))
  end

  describe "infer/5 (#328)" do
    setup do
      now = DateTime.utc_now()
      %{now: now, window: 45 * 60, unanswered: 90 * 60}
    end

    test "a recent action reads present", %{now: now, window: w, unanswered: u} do
      recent = DateTime.add(now, -10 * 60, :second)
      assert {:present, ^recent, :recent_action} = Presence.infer(recent, nil, w, u, now)
    end

    test "an unanswered request past its window reads away", %{now: now, window: w, unanswered: u} do
      stale = DateTime.add(now, -3 * 3600, :second)
      waiting = DateTime.add(now, -2 * 3600, :second)

      assert {:away, ^stale, {:unanswered, ^waiting}} =
               Presence.infer(stale, waiting, w, u, now)
    end

    test "a request still inside its window is not yet absence", %{
      now: now,
      window: w,
      unanswered: u
    } do
      stale = DateTime.add(now, -3 * 3600, :second)
      waiting = DateTime.add(now, -30 * 60, :second)

      assert {:present, ^stale, :nothing_waiting} = Presence.infer(stale, waiting, w, u, now)
    end

    test "nothing waiting and nothing recent stays present", %{now: now, window: w, unanswered: u} do
      stale = DateTime.add(now, -8 * 3600, :second)

      # a quiet fleet used to make a present operator look absent
      assert {:present, ^stale, :nothing_waiting} = Presence.infer(stale, nil, w, u, now)
      assert {:present, nil, :nothing_waiting} = Presence.infer(nil, nil, w, u, now)
    end

    test "a recent action outranks an aged request", %{now: now, window: w, unanswered: u} do
      recent = DateTime.add(now, -2 * 60, :second)
      waiting = DateTime.add(now, -5 * 3600, :second)

      # someone who just clicked is here, whatever is sitting unanswered
      assert {:present, ^recent, :recent_action} = Presence.infer(recent, waiting, w, u, now)
    end
  end

  test "an open ask counts as an unanswered request until it is answered (#328)" do
    before = Presence.oldest_unanswered_request()

    {:ok, ask} = Custode.Asks.ask(uid("presence-agent"), "which repo first?")

    oldest = Presence.oldest_unanswered_request()
    assert oldest != nil
    assert before == nil or DateTime.compare(oldest, before) in [:lt, :eq]

    {:ok, _answered} = Custode.Asks.answer(ask.id, "the one with the red main")

    after_answer = Presence.oldest_unanswered_request()
    assert after_answer == before
  end

  test "render says what the reading rests on (#328)" do
    now = DateTime.utc_now()

    Application.put_env(:custode, :presence_override, {:present, now})
    rendered = Presence.render(now)
    assert rendered =~ "operator: PRESENT"
    assert rendered =~ "pinned present"

    Application.put_env(:custode, :presence_override, :away)
    assert Presence.render(now) =~ "pinned away"
  end

  test "an assumed present does not read like an evidenced one (#328)" do
    now = DateTime.utc_now()
    recent = DateTime.add(now, -3 * 60, :second)
    stale = DateTime.add(now, -9 * 3600, :second)
    waiting = DateTime.add(now, -4 * 3600, :second)

    # a sweep can only weigh the reading if it can see what it rests on
    assert {:present, _at, :recent_action} = Presence.infer(recent, nil, 2700, 5400, now)
    assert {:present, _at, :nothing_waiting} = Presence.infer(stale, nil, 2700, 5400, now)
    assert {:away, _at, {:unanswered, _since}} = Presence.infer(stale, waiting, 2700, 5400, now)
  end

  test "render produces the one-line tick context either way" do
    Application.put_env(:custode, :presence_override, :present)
    assert Presence.render() =~ "operator: PRESENT"

    Application.put_env(:custode, :presence_override, :away)
    assert Presence.render() =~ "operator: AWAY"
  end

  test "set/1: away pins, present pins, auto restores inference with a fresh action (#141)" do
    started = DateTime.to_iso8601(DateTime.utc_now())

    assert {:away, _at} = Presence.set(:away)
    assert {:away, _at} = Presence.status()

    assert {:present, _at} = Presence.set(:present)
    assert {:present, _at} = Presence.status()

    # auto clears the pin, and the toggle itself was an operator action --
    # so the reading is present NOW and will expire with the window, not pin
    assert {:present, at} = Presence.set(:auto)
    assert %DateTime{} = at
    assert Application.get_env(:custode, :presence_override) == nil

    # Each toggle went on the record. Counted from when this test began: the
    # feed is shared, other modules toggle presence in their setup (the aging
    # tests do it twice per test), and an unscoped count of the operator's
    # last 30 entries read 30 whenever one of them happened to run first.
    toggles =
      "operator"
      |> Custode.Feed.for_agent()
      |> Enum.filter(&(&1["event"] == "presence" and &1["at"] >= started))

    assert length(toggles) == 3
  end

  test "the tick-args system prompt carries the presence line at fire time" do
    workspace = tmp_workspace!()
    id = uid("routine")

    put_env!(:routines, [%{id: id, cron: "@daily", workspace: workspace, prompt: "sweep"}])

    Application.put_env(:custode, :presence_override, :away)
    args = Custode.Routine.tick_args(Custode.Routine.get(id))
    assert args["start"]["args"]["append_system_prompt"] =~ "operator: AWAY"

    # a presence flip reaches the very next tick, no restart (#121/#142)
    Application.put_env(:custode, :presence_override, :present)
    args = Custode.Routine.tick_args(Custode.Routine.get(id))
    assert args["start"]["args"]["append_system_prompt"] =~ "operator: PRESENT"
  end
end
