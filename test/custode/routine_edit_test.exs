defmodule Custode.Operator.RoutineEditTest do
  use ExUnit.Case, async: true

  alias Custode.Operator.RoutineEdit

  @raw %{cron: "@daily", model: nil, daily_budget_usd: 25.0, tags: [:repo, :rust], max_turns: 40}

  test "a raw entry reads as form strings: nil is blank, a list is comma separated" do
    strings = RoutineEdit.strings(@raw)

    assert strings["cron"] == "@daily"
    assert strings["model"] == ""
    assert strings["daily_budget_usd"] == "25.0"
    assert strings["tags"] == "repo, rust"
    assert Map.keys(strings) |> Enum.sort() == Enum.sort(RoutineEdit.fields())
  end

  test "a manual cadence round-trips as the word" do
    assert RoutineEdit.strings(%{cron: :manual})["cron"] == "manual"
  end

  test "an untouched form is no change" do
    strings = RoutineEdit.strings(@raw)
    assert RoutineEdit.changes(strings, strings) == {:ok, %{}}
  end

  test "changes are typed: numbers parse, tags become atoms" do
    original = RoutineEdit.strings(@raw)

    submitted =
      Map.merge(original, %{
        "daily_budget_usd" => "75.5",
        "max_turns" => "60",
        "tags" => "repo, upkeep"
      })

    assert {:ok, %{daily_budget_usd: 75.5, max_turns: 60, tags: [:repo, :upkeep]}} =
             RoutineEdit.changes(original, submitted)
  end

  test "a blank field clears the override, so the routine inherits again" do
    original = RoutineEdit.strings(@raw)

    assert {:ok, %{daily_budget_usd: nil}} =
             RoutineEdit.changes(original, Map.put(original, "daily_budget_usd", ""))
  end

  test "the first value that does not parse refuses the whole save and names the field" do
    original = RoutineEdit.strings(@raw)
    submitted = Map.merge(original, %{"max_turns" => "plenty", "cron" => "@weekly"})

    assert {:error, message} = RoutineEdit.changes(original, submitted)
    assert message =~ "max_turns must be an integer"
  end

  test "an unknown effort is refused without minting an atom" do
    original = RoutineEdit.strings(@raw)

    assert {:error, message} =
             RoutineEdit.changes(original, Map.put(original, "effort", "heroic-nonexistent"))

    assert message =~ "unknown effort"
  end
end
