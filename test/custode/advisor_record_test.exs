defmodule Custode.Advisors.RecordTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Advisors.Record
  alias Custode.Feed
  alias Custode.Suggestions

  @now ~U[2026-07-27 12:00:00.000000Z]

  setup do
    path = Path.join(System.tmp_dir!(), uid("advrec") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    clean = fn ->
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'advisor_%'")
      Custode.Repo.query!("DELETE FROM spend")
    end

    clean.()
    on_exit(clean)

    %{workspace: tmp_workspace!()}
  end

  defp suggest!(advisor, agent, field, proposed) do
    Feed.record(%{
      event: "advisor_suggestion",
      agent: agent,
      advisor: advisor,
      field: field,
      current: "@daily",
      proposed: proposed,
      evidence: "because"
    })
  end

  defp applied!(advisor, agent, field, proposed, ago) do
    at = DateTime.add(@now, -ago, :second)

    Custode.Repo.insert!(%Feed.Entry{
      event: "advisor_applied",
      agent: agent,
      at: at,
      entry:
        Jason.encode!(%{
          "event" => "advisor_applied",
          "agent" => agent,
          "advisor" => advisor,
          "field" => field,
          "proposed" => proposed,
          "at" => DateTime.to_iso8601(at)
        })
    })
  end

  defp record_for(advisor, opts \\ []) do
    opts |> Keyword.put_new(:now, @now) |> Record.all() |> Enum.find(&(&1.advisor == advisor))
  end

  defp routine!(workspace, fields) do
    routine = Enum.into(fields, %{cron: "@daily", workspace: workspace, prompt: "s"})
    put_env!(:routines, [routine])
    routine.id
  end

  describe "all/1" do
    test "counts what an advisor proposed and what became of it", %{workspace: workspace} do
      id = routine!(workspace, id: uid("rec"), daily_budget_usd: 450.0)

      applied!("advisor-budget", id, "daily_budget_usd", "450.0", 10 * 86_400)
      {:ok, _msg} = Suggestions.dismiss(id, "cron", "@weekly", "not_now")
      suggest!("advisor-budget", id, "model", "haiku")

      record = record_for("advisor-budget")

      assert record.applied == 1
      assert record.settled == 1
      assert record.standing == 1
    end

    test "a change the roster no longer holds counts as reverted", %{workspace: workspace} do
      id = routine!(workspace, id: uid("rev"), daily_budget_usd: 300.0)
      applied!("advisor-budget", id, "daily_budget_usd", "450.0", 86_400)

      assert record_for("advisor-budget").reverted == 1
    end

    test "busiest advisor first", %{workspace: workspace} do
      id = routine!(workspace, id: uid("busy"))

      suggest!("advisor-cadence", id, "cron", "@hourly")
      suggest!("advisor-model", id, "model", "haiku")
      suggest!("advisor-model", id, "cron", "@weekly")

      assert [%{advisor: "advisor-model"} | _rest] = Record.all(now: @now)
    end

    test "an advisor that has said nothing does not appear" do
      assert Record.all(now: @now) == []
    end
  end

  describe "dismissal reasons" do
    test "are broken out, because they are not the same failure",
         %{workspace: workspace} do
      id = routine!(workspace, id: uid("reasons"))

      # a dismissal always follows a proposal, and it is recorded against the
      # advisor that made it -- that attribution is the whole point
      suggest!("advisor-cadence", id, "cron", "@weekly")
      suggest!("advisor-cadence", id, "model", "haiku")
      suggest!("advisor-cadence", id, "daily_budget_usd", "1.0")

      {:ok, _a} = Suggestions.dismiss(id, "cron", "@weekly", "not_now")
      {:ok, _b} = Suggestions.dismiss(id, "model", "haiku", "not_now")
      {:ok, _c} = Suggestions.dismiss(id, "daily_budget_usd", "1.0", "disagree")

      record = record_for("advisor-cadence")

      assert record.dismissed == 3
      assert record.dismissed_by_reason["not_now"] == 2
      assert record.dismissed_by_reason["disagree"] == 1
    end

    test "a reasonless dismissal groups under unsaid rather than vanishing",
         %{workspace: workspace} do
      id = routine!(workspace, id: uid("unsaid"))
      suggest!("advisor-cadence", id, "cron", "@weekly")
      {:ok, _a} = Suggestions.dismiss(id, "cron", "@weekly")

      assert record_for("advisor-cadence").dismissed_by_reason["unsaid"] == 1
    end
  end

  describe "grade and cost" do
    test "the deterministic advisors are free, and that is the answer" do
      grades = Record.grades()

      assert grades["advisor-budget"] == :deterministic
      assert grades["advisor-cadence"] == :deterministic
      assert grades["advisor-model"] == :deterministic
    end

    test "only the judgment advisor has a cost worth asking about" do
      assert Record.grades()["advisor-retro"] == :judgment
    end

    test "a judgment advisor's spend is attributed to it", %{workspace: workspace} do
      id = routine!(workspace, id: uid("cost"))
      suggest!("advisor-retro", id, "cron", "@weekly")

      Custode.Repo.insert!(%Custode.SpendLedger.Entry{
        agent_id: "advisor-retro",
        cost_usd: 0.11,
        outcome: "turn",
        inserted_at: DateTime.add(@now, -86_400, :second)
      })

      record = record_for("advisor-retro")
      assert_in_delta record.cost_usd, 0.11, 0.001
      assert Record.describe(record) =~ "cost $0.11"
    end

    test "a deterministic advisor reads as free, not as zero dollars",
         %{workspace: workspace} do
      id = routine!(workspace, id: uid("free"))
      suggest!("advisor-budget", id, "cron", "@weekly")

      assert Record.describe(record_for("advisor-budget")) =~ "free"
    end
  end
end
