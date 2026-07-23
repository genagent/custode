defmodule Custode.PanelsTest do
  # Agent-authored panels, gated (#100 v1): the propose -> approve/reject ->
  # render lifecycle and the mode gate. The sandboxing itself is asserted in
  # the LiveView test (the render site is the boundary).
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Panels

  setup do
    previous = Application.get_env(:custode, :agent_panels)
    on_exit(fn -> Application.put_env(:custode, :agent_panels, previous) end)
    put_env!(:agent_panels, :gated)

    # The suite runs against a persistent on-disk sqlite file and
    # `test_helper.exs` truncates only the tables it knows about -- not
    # `agent_panels`. `uid/1`'s counter restarts every VM run, so a second
    # local run regenerates the same routine ids and reads the previous run's
    # versions: `revertable?/1` counts them and the count-based assertions
    # drift (#253). Every panel-touching test is `async: false`, so clearing
    # the log outright is safe.
    clear_panels!()
    on_exit(&clear_panels!/0)

    %{id: uid("panelist")}
  end

  test "gated: a proposal is pending until approved; then it is current", %{id: id} do
    assert Panels.current(id) == nil
    assert Panels.pending(id) == nil

    {:ok, _} = Panels.set(id, "<b>watchlist</b>")
    assert Panels.pending(id) == "<b>watchlist</b>"
    # not current until approved
    assert Panels.current(id) == nil

    :ok = Panels.approve(id)
    assert Panels.current(id) == "<b>watchlist</b>"
    assert Panels.pending(id) == nil
  end

  test "reject leaves the current panel untouched", %{id: id} do
    {:ok, _} = Panels.set(id, "<b>v1</b>")
    :ok = Panels.approve(id)

    {:ok, _} = Panels.set(id, "<b>v2 proposal</b>")
    assert Panels.pending(id) == "<b>v2 proposal</b>"

    :ok = Panels.reject(id)
    assert Panels.pending(id) == nil
    assert Panels.current(id) == "<b>v1</b>"
  end

  test "revert restores the previous approved version", %{id: id} do
    {:ok, _} = Panels.set(id, "<b>first</b>")
    :ok = Panels.approve(id)
    refute Panels.revertable?(id)

    {:ok, _} = Panels.set(id, "<b>second</b>")
    :ok = Panels.approve(id)
    assert Panels.current(id) == "<b>second</b>"
    assert Panels.revertable?(id)

    :ok = Panels.revert(id)
    assert Panels.current(id) == "<b>first</b>"
  end

  test "auto mode approves on arrival; off refuses", %{id: id} do
    put_env!(:agent_panels, :auto)
    {:ok, row} = Panels.set(id, "<b>trusted</b>")
    assert row.status == "approved"
    assert Panels.current(id) == "<b>trusted</b>"

    put_env!(:agent_panels, :off)
    assert Panels.set(id, "<b>nope</b>") == {:error, :panels_off}
  end

  test "an oversize fragment is refused", %{id: id} do
    assert Panels.set(id, String.duplicate("x", 20_001)) == {:error, :too_large}
  end

  test "a routine id does not inherit an earlier run's versions (#253)" do
    # A FIXED id on purpose: it makes the cross-run collision `uid/1` produces
    # by accident permanent, so this test fails on the second local run if the
    # setup clearing goes away -- exactly the reported symptom.
    id = "panelist-253"

    assert Panels.current(id) == nil
    assert Panels.pending(id) == nil

    {:ok, _} = Panels.set(id, "<b>first</b>")
    :ok = Panels.approve(id)
    refute Panels.revertable?(id)
  end

  defp clear_panels!, do: Custode.Repo.query!("DELETE FROM agent_panels")
end
