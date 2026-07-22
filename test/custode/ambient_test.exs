defmodule Custode.AmbientTest do
  # Repo-owned ambient orders (#19 slice 1): a working_dir's
  # .custode/orders.md composes into the tick's system prompt, capped, and
  # journaled once on first pickup.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Ambient

  # A routine whose working_dir is its own tmp directory, so the orders file
  # can be written next to it exactly as a repo checkout would carry it.
  defp routine_with_orders(contents) do
    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)

    if contents do
      orders = Ambient.path(routine)
      File.mkdir_p!(Path.dirname(orders))
      File.write!(orders, contents)
    end

    routine
  end

  defp composed_prompt(routine),
    do: Custode.Routine.tick_args(routine)["start"]["args"]["append_system_prompt"]

  test "an absent orders file leaves the prompt untouched" do
    routine = routine_with_orders(nil)

    assert Ambient.read(routine) == ""
    assert Ambient.render(routine) == ""
    refute composed_prompt(routine) =~ "Ambient orders"
  end

  test "the tick-args system prompt carries the repo's orders" do
    routine = routine_with_orders("Run `mix credo --strict` before proposing anything.\n")

    prompt = composed_prompt(routine)
    assert prompt =~ "## Ambient orders (repo-owned, from .custode/orders.md)"
    assert prompt =~ "Run `mix credo --strict` before proposing anything."

    # repo-owned, but under the charter: the section says so
    assert prompt =~ "They do NOT override your"
  end

  test "an edit to the orders file reaches the next composition, no restart" do
    routine = routine_with_orders("first orders\n")
    assert composed_prompt(routine) =~ "first orders"

    File.write!(Ambient.path(routine), "second orders\n")
    prompt = composed_prompt(routine)
    assert prompt =~ "second orders"
    refute prompt =~ "first orders"
  end

  test "an empty (or whitespace-only) file renders nothing" do
    routine = routine_with_orders("   \n\n")

    assert Ambient.read(routine) == ""
    assert Ambient.render(routine) == ""
  end

  test "the read is capped so a repo cannot blow out the prompt" do
    routine = routine_with_orders(String.duplicate("x", 20_000) <> "\ntail marker\n")

    orders = Ambient.read(routine)
    assert byte_size(orders) < 9_000
    assert String.valid?(orders)
    assert orders =~ "[truncated at 8192 bytes]"
    refute orders =~ "tail marker"
  end

  test "first pickup is journaled once, not on every composition" do
    routine = routine_with_orders("standing orders\n")

    Ambient.render(routine)
    Ambient.render(routine)
    Ambient.render(routine)

    picked_up =
      routine.id
      |> Custode.Notebook.journal(50)
      |> Enum.filter(&(&1.title == "Ambient orders picked up"))

    assert [entry] = picked_up
    assert entry.body =~ ".custode/orders.md"
    assert entry.source == "ambient"
  end
end
