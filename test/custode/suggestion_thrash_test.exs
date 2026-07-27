defmodule Custode.SuggestionThrashTest do
  @moduledoc """
  The thrash guard (#303). Masking stops the same change being re-proposed;
  this stops the OPPOSITE one, which is the loop design/005 names: an advisor
  lowers a rail, the lower rail starts stopping work, and the next sweep
  proposes raising it.
  """

  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Feed
  alias Custode.Suggestions

  setup do
    path = Path.join(System.tmp_dir!(), uid("thrash") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    clean = fn -> Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'advisor_%'") end
    clean.()
    on_exit(clean)

    %{agent: uid("thrash-agent")}
  end

  defp suggest!(agent, field, proposed) do
    Feed.record(%{
      event: "advisor_suggestion",
      agent: agent,
      advisor: "advisor-budget",
      field: field,
      current: "300.0",
      proposed: proposed,
      evidence: "because"
    })
  end

  defp applied!(agent, field, proposed, ago) do
    at = DateTime.add(DateTime.utc_now(), -ago, :second)

    Custode.Repo.insert!(%Feed.Entry{
      event: "advisor_applied",
      agent: agent,
      at: at,
      entry:
        Jason.encode!(%{
          "event" => "advisor_applied",
          "agent" => agent,
          "advisor" => "advisor-budget",
          "field" => field,
          "proposed" => proposed,
          "at" => DateTime.to_iso8601(at)
        })
    })
  end

  defp standing_for(agent), do: Enum.filter(Suggestions.standing(), &(&1["agent"] == agent))

  test "the opposite change is held back while the parameter rests", %{agent: agent} do
    applied!(agent, "daily_budget_usd", "55.0", 86_400)

    # a locally reasonable proposal: the lower rail is now stopping work
    suggest!(agent, "daily_budget_usd", "450.0")

    assert standing_for(agent) == []
  end

  test "the same parameter is free again once the dwell has passed", %{agent: agent} do
    applied!(agent, "daily_budget_usd", "55.0", Suggestions.dwell_seconds() + 86_400)
    suggest!(agent, "daily_budget_usd", "450.0")

    assert [%{"proposed" => "450.0"}] = standing_for(agent)
  end

  test "a DIFFERENT parameter on the same agent is untouched", %{agent: agent} do
    applied!(agent, "daily_budget_usd", "55.0", 86_400)
    suggest!(agent, "cron", "@weekly")

    assert [%{"field" => "cron"}] = standing_for(agent)
  end

  test "the same parameter on a different agent is untouched", %{agent: agent} do
    other = uid("other")
    applied!(agent, "daily_budget_usd", "55.0", 86_400)
    suggest!(other, "daily_budget_usd", "450.0")

    assert [%{"agent" => ^other}] = standing_for(other)
  end

  test "a dismissal does not start a dwell -- nothing was changed", %{agent: agent} do
    suggest!(agent, "daily_budget_usd", "55.0")
    {:ok, _msg} = Suggestions.dismiss(agent, "daily_budget_usd", "55.0", "disagree")

    # the dismissed change stays masked, but the PARAMETER is not resting, so
    # a genuinely different proposal still reaches the operator
    suggest!(agent, "daily_budget_usd", "450.0")
    assert [%{"proposed" => "450.0"}] = standing_for(agent)
  end

  test "resting_parameters keys on the parameter, not the change", %{agent: agent} do
    applied!(agent, "daily_budget_usd", "55.0", 86_400)

    resting = Suggestions.resting_parameters()
    assert MapSet.member?(resting, {agent, "daily_budget_usd"})
    refute MapSet.member?(resting, {agent, "cron"})
  end
end
