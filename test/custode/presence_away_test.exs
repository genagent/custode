defmodule Custode.PresenceAwayTest do
  # The away-window gap logic (#263). The pure finder is tested directly with
  # constructed timelines (robust against the shared DB); away_window/1 is
  # checked for the away short-circuit.
  use ExUnit.Case, async: true

  alias Custode.Presence

  @window 2_700

  defp ago(now, seconds), do: DateTime.add(now, -seconds, :second)

  test "a real absence surfaces the older side of the most recent gap" do
    now = DateTime.utc_now()
    # returned 1 min ago; the prior action was 3h before that
    actions = [ago(now, 60), ago(now, 60 + 3 * 3600)]

    assert {:since, since} = Presence.away_from(actions, @window, now)
    assert DateTime.compare(since, ago(now, 3 * 3600)) == :lt
  end

  test "continuous recent presence (no gap >= window) is :none" do
    now = DateTime.utc_now()
    actions = [ago(now, 60), ago(now, 600), ago(now, 1200)]
    assert Presence.away_from(actions, @window, now) == :none
  end

  test "an absence whose RETURN is stale (operator back a while) is :none" do
    now = DateTime.utc_now()
    # a genuine 3h gap, but the return was 2h ago -- not 'just returned'
    ret = ago(now, 2 * 3600)
    actions = [ret, ago(ret, 3 * 3600)]
    assert Presence.away_from(actions, @window, now) == :none
  end

  test "the most recent of several absences wins" do
    now = DateTime.utc_now()
    # recent return, an absence just before, and an older absence earlier
    actions = [ago(now, 30), ago(now, 30 + 2 * 3600), ago(now, 30 + 2 * 3600 + 5 * 3600)]
    assert {:since, since} = Presence.away_from(actions, @window, now)
    # the MOST recent gap (2h) -> since is ~2h before the return, not 7h
    assert DateTime.diff(now, since) < 3 * 3600
  end

  test "too few actions is :none" do
    now = DateTime.utc_now()
    assert Presence.away_from([now], @window, now) == :none
    assert Presence.away_from([], @window, now) == :none
  end

  test "away_window short-circuits to :none while the operator is away" do
    previous = Application.get_env(:custode, :presence_override)
    Application.put_env(:custode, :presence_override, :away)
    on_exit(fn -> Application.put_env(:custode, :presence_override, previous) end)

    assert Presence.away_window() == :none
  end
end
