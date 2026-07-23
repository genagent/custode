defmodule Custode.Advisors.RetroTest do
  # The first judgment-grade advisor (#262): observe builds the Digest, suggest
  # makes one bounded LLM call over it. The call is stubbed via the
  # :advisor_query_fun seam, so no real tokens are spent.
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import ObanClaude.Testing

  alias Custode.Advisors.{Cadence, Retro}

  setup do
    feed = Path.join(System.tmp_dir!(), uid("retro-feed") <> ".jsonl")
    put_env!(:feed_path, feed)

    on_exit(fn ->
      File.rm(feed)
      Application.delete_env(:custode, :advisor_query_fun)
    end)

    :ok
  end

  defp stub(suggestions) do
    Application.put_env(
      :custode,
      :advisor_query_fun,
      respond(structured_result(%{"suggestions" => suggestions}))
    )
  end

  test "grade is :judgment for Retro and defaults to :deterministic for the trio" do
    assert Retro.grade() == :judgment
    assert Cadence.grade() == :deterministic
  end

  test "suggest maps the stubbed structured output into typed suggestion maps" do
    stub([
      %{
        "routine_id" => "redisctl",
        "field" => "cron",
        "current" => "*/10 * * * *",
        "proposed" => "@daily",
        "evidence" => "idle 6 of 7 sweeps",
        "confidence" => "medium"
      }
    ])

    digest = Custode.Digest.build(1)
    assert [s] = Retro.suggest([digest])
    assert s.routine_id == "redisctl"
    assert s.field == "cron"
    assert s.proposed == "@daily"
    assert s.confidence == "medium"
  end

  test "a full run records the suggestion through the same feed path as the trio" do
    stub([
      %{
        "routine_id" => "reviewer",
        "field" => "cron",
        "current" => "@daily",
        "proposed" => "0 9-17 * * 1-5",
        "evidence" => "queue only builds on weekdays",
        "confidence" => "high"
      }
    ])

    :ok = Custode.Advisor.run(Retro)

    assert [%{"event" => "advisor_suggestion"} = entry] = Custode.Feed.for_agent("reviewer")
    assert entry["advisor"] == "advisor-retro"
    assert entry["proposed"] == "0 9-17 * * 1-5"
  end

  test "malformed suggestions are dropped, never crash the sensor lane" do
    # missing routine_id -> dropped; the call still succeeds with no output
    stub([%{"field" => "cron", "proposed" => "@daily"}])
    assert Retro.suggest([Custode.Digest.build(1)]) == []

    # a non-suggestions payload yields nothing, not a crash
    Application.put_env(:custode, :advisor_query_fun, respond(structured_result(%{"other" => 1})))
    assert Retro.suggest([Custode.Digest.build(1)]) == []
  end
end
