defmodule Custode.SuggestionsTest do
  # The shared suggestions context (#284): standing/0 dedups and masks applied
  # ones; apply/3 writes through the roster and records advisor_applied.
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Suggestions

  setup do
    feed = Path.join(System.tmp_dir!(), uid("sugg-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    Custode.Repo.query!(
      "DELETE FROM feed_entries WHERE event IN ('advisor_suggestion','advisor_applied','advisor_dismissed')"
    )

    on_exit(fn -> File.rm(feed) end)
    :ok
  end

  defp suggest!(agent, field, proposed) do
    Custode.Feed.record(%{
      event: "advisor_suggestion",
      agent: agent,
      advisor: "advisor-cadence",
      field: field,
      current: "@daily",
      proposed: proposed,
      confidence: "medium",
      evidence: "evidence for #{agent}"
    })
  end

  test "standing/0 lists suggestions, deduped by advisor+agent+field" do
    a = uid("r")
    suggest!(a, "cron", "@weekly")
    suggest!(a, "cron", "@daily")

    standing = Suggestions.standing()
    mine = Enum.filter(standing, &(&1["agent"] == a))
    assert length(mine) == 1
    # the newest read wins
    assert hd(mine)["proposed"] == "@daily"
  end

  test "standing/0 masks a suggestion once applied" do
    a = uid("r")
    suggest!(a, "cron", "@daily")
    assert Enum.any?(Suggestions.standing(), &(&1["agent"] == a))

    Custode.Feed.record(%{event: "advisor_applied", agent: a, field: "cron", proposed: "@daily"})
    refute Enum.any?(Suggestions.standing(), &(&1["agent"] == a))
  end

  test "apply/3 writes through the roster and records advisor_applied" do
    roster = Path.join(System.tmp_dir!(), uid("apply-roster") <> ".toml")
    System.put_env("CUSTODE_CONFIG", roster)
    previous = Application.get_env(:custode, :routines)

    on_exit(fn ->
      System.delete_env("CUSTODE_CONFIG")
      File.rm(roster)
      Application.put_env(:custode, :routines, previous)
    end)

    ws = tmp_workspace!()
    id = uid("wk")
    put_env!(:routines, [%{id: id, cron: "@daily", workspace: ws, prompt: "s"}])

    assert {:ok, msg} = Suggestions.apply(id, "model", "haiku")
    assert msg =~ "applied"
    assert Custode.Routine.get(id).model == "haiku"
    # and it now masks the suggestion
    refute Enum.any?(Suggestions.standing(), &(&1["agent"] == id and &1["field"] == "model"))
  end

  test "apply/3 refuses an unapplicable field" do
    assert {:error, {:unapplicable_field, "repo"}} = Suggestions.apply("x", "repo", "a/b")
  end

  test "dismiss/3 masks the suggestion for the window, even a re-proposal (#290)" do
    a = uid("r")
    suggest!(a, "cron", "@daily")
    assert Enum.any?(Suggestions.standing(), &(&1["agent"] == a))

    assert {:ok, _} = Suggestions.dismiss(a, "cron", "@daily")
    refute Enum.any?(Suggestions.standing(), &(&1["agent"] == a))

    # the advisor re-proposes the same change -> still masked
    suggest!(a, "cron", "@daily")
    refute Enum.any?(Suggestions.standing(), &(&1["agent"] == a))
  end
end
