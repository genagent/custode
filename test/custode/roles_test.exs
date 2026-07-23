defmodule Custode.RolesTest do
  # The role registry (leaning into distinct roles): the single source of
  # truth for what roles exist and where each sits in the fleet hierarchy.
  # The load-bearing tests are the drift guards -- a registry that disagrees
  # with the prompt stack or the pre-refactor allowlist is worse than none.
  use ExUnit.Case, async: true

  alias Custode.Roles
  alias Custode.Routine.Prompts

  test "every registered role composes a prompt (registry <-> prompt stack alignment)" do
    for {role, _meta} <- Roles.all() do
      prompt = Prompts.for_role(role, "unit-#{role}")
      assert prompt =~ "## Your role", "#{role} has a registry entry but no role prompt"
    end
  end

  test "grants derive from tier and preserve the pre-registry allowlist exactly" do
    # before the registry, ONLY the caretaker was elevated; every other role
    # got the worker set. The tier -> grants derivation must reproduce that.
    assert Roles.grants(:caretaker) == :operator
    assert Roles.tier(:caretaker) == :custode

    for {role, _} <- Roles.all(), role != :caretaker do
      assert Roles.grants(role) == :worker, "#{role} must not be elevated"
      assert Roles.tier(role) in [:specialist], "#{role} should be a specialist"
    end
  end

  test "the custode agent is the singleton apex of the routine hierarchy" do
    assert Roles.singleton?(:caretaker)
    # it is the only tier above the specialists, and the only one granted
    # operator tools
    elevated = for {role, _} <- Roles.all(), Roles.grants(role) == :operator, do: role
    assert elevated == [:caretaker]
  end

  test "the hierarchy is a tree from operator down to sub-agent" do
    assert Roles.tiers() == [:operator, :custode, :specialist, :sub_agent]
  end

  test "an unknown role reads as the least-privileged default" do
    # #161: a roster entry that forgets its role gets the assistant's floor,
    # never an accidental elevation
    assert Roles.tier(:no_such_role) == :specialist
    assert Roles.grants(:no_such_role) == :worker
    refute Roles.known?(:no_such_role)
  end

  test "every role carries the metadata a tile and the agent page read" do
    for {role, meta} <- Roles.all() do
      assert is_binary(meta.summary) and meta.summary != "", "#{role} summary"
      assert meta.cadence in [:active, :quiet], "#{role} cadence"
      assert is_atom(meta.watches), "#{role} watches"
      assert is_list(meta.writes) and meta.writes != [], "#{role} writes"
    end
  end
end
