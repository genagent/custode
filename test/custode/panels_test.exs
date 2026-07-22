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
end
