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

  test "presence decays to away outside the window, and the override pins it" do
    # evaluate NOW as if it were far in the future: whatever evidence exists
    # is stale by then, so inference reads away
    future = DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second)
    assert {:away, _last} = Presence.status(future)

    # the explicit override wins in both directions
    Application.put_env(:custode, :presence_override, :present)
    assert {:present, _} = Presence.status(future)

    Application.put_env(:custode, :presence_override, :away)
    assert {:away, _} = Presence.status()
  end

  test "render produces the one-line tick context either way" do
    Application.put_env(:custode, :presence_override, :present)
    assert Presence.render() =~ "operator: PRESENT"

    Application.put_env(:custode, :presence_override, :away)
    assert Presence.render() =~ "operator: AWAY"
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
