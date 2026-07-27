defmodule Custode.Suggestions.OutcomeTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Feed
  alias Custode.Suggestions.Outcome

  @now ~U[2026-07-26 12:00:00.000000Z]

  setup do
    path = Path.join(System.tmp_dir!(), uid("outcome") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    clean = fn ->
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'advisor_%'")
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event = 'budget_paused'")
      Custode.Repo.query!("DELETE FROM spend")
    end

    clean.()
    on_exit(clean)

    workspace = tmp_workspace!()
    %{workspace: workspace}
  end

  # An applied entry dated `ago` seconds before @now.
  defp applied!(agent, field, proposed, ago) do
    Custode.Repo.insert!(%Feed.Entry{
      event: "advisor_applied",
      agent: agent,
      at: DateTime.add(@now, -ago, :second),
      entry:
        Jason.encode!(%{
          "event" => "advisor_applied",
          "agent" => agent,
          "advisor" => "advisor-budget",
          "field" => field,
          "proposed" => proposed,
          "at" => DateTime.add(@now, -ago, :second) |> DateTime.to_iso8601()
        })
    })
  end

  defp history, do: Outcome.history(now: @now)
  defp record_for(agent), do: Enum.find(history(), &(&1.agent == agent))

  defp routine_with!(workspace, fields) do
    routine = Enum.into(fields, %{cron: "@daily", workspace: workspace, prompt: "s"})
    put_env!(:routines, [routine])
    routine.id
  end

  describe "status" do
    test "an applied change still in force, inside the window, is observing",
         %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("obs"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", 60 * 60)

      assert record_for(id).status == :observing
    end

    test "the same change once the window has elapsed is settled", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("settled"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", (Outcome.observation_days() + 1) * 86_400)

      assert record_for(id).status == :settled
    end

    test "settled does NOT claim the advice was right", %{workspace: workspace} do
      # the record carries facts; a verdict needs a per-advisor claim to test
      id = routine_with!(workspace, id: uid("noverdict"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", 10 * 86_400)

      refute record_for(id).status in [:confirmed, :no_effect]
      assert record_for(id).observed != nil
    end

    test "a roster that no longer holds the value is reverted", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("rev"), daily_budget_usd: 300.0)
      applied!(id, "daily_budget_usd", "450.0", 86_400)

      record = record_for(id)
      assert record.status == :reverted
      assert Outcome.describe(record) =~ "no longer holds 450.0"
    end

    test "an agent gone from the roster is superseded, not reverted", %{workspace: workspace} do
      # superseded first: "reverted" would imply a decision about the CHANGE
      # rather than about the agent
      _other = routine_with!(workspace, id: uid("survivor"))
      applied!("vanished-#{System.unique_integer([:positive])}", "cron", "@daily", 86_400)

      assert Enum.any?(history(), &(&1.status == :superseded))
    end

    test "a model change reads the same way as a budget one", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("model"), model: "sonnet")
      applied!(id, "model", "sonnet", 86_400)

      assert record_for(id).status == :observing
    end
  end

  describe "observed facts" do
    test "counts rail-stops and the peak DAY of spend since the change",
         %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("facts"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", 6 * 86_400)

      # two days of spend since, so the peak is a day and not the total
      for {ago, usd} <- [{5 * 86_400, 100.0}, {5 * 86_400, 12.4}, {2 * 86_400, 90.0}] do
        Custode.Repo.insert!(%Custode.SpendLedger.Entry{
          agent_id: id,
          cost_usd: usd,
          outcome: "turn",
          inserted_at: DateTime.add(@now, -ago, :second)
        })
      end

      Custode.Repo.insert!(%Feed.Entry{
        event: "budget_paused",
        agent: id,
        at: DateTime.add(@now, -4 * 86_400, :second),
        entry: Jason.encode!(%{"event" => "budget_paused", "agent" => id})
      })

      observed = record_for(id).observed

      assert observed.days == 6
      assert observed.rail_stops == 1
      assert_in_delta observed.peak_usd, 112.4, 0.001
    end

    test "no spend and no stops is zero, not nil", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("quiet"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", 86_400)

      observed = record_for(id).observed
      assert observed.rail_stops == 0
      assert observed.peak_usd == 0.0
    end

    test "describe reads as the sentence the design deck asked for",
         %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("sentence"), daily_budget_usd: 450.0)
      applied!(id, "daily_budget_usd", "450.0", 6 * 86_400)

      sentence = Outcome.describe(record_for(id))

      assert sentence =~ "applied 6d ago"
      assert sentence =~ "0 rail-stop(s) since"
      assert sentence =~ "peak $0.00"
    end
  end

  describe "dismissals" do
    test "appear in the record, carrying their reason", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("dis"))
      {:ok, _message} = Custode.Suggestions.dismiss(id, "cron", "@weekly", "not_now")

      record = record_for(id)
      assert record.decision == :dismissed
      assert record.status == :dismissed
      assert record.reason == "not_now"
      assert Outcome.describe(record) == "dismissed: right, but not now"
    end

    test "a reasonless dismissal still reads honestly", %{workspace: workspace} do
      id = routine_with!(workspace, id: uid("dis-bare"))
      {:ok, _message} = Custode.Suggestions.dismiss(id, "cron", "@weekly")

      assert Outcome.describe(record_for(id)) == "dismissed"
    end
  end

  describe "history/1" do
    test "is newest first across both decision kinds", %{workspace: workspace} do
      old = routine_with!(workspace, id: uid("old"))
      applied!(old, "cron", "@daily", 5 * 86_400)
      {:ok, _message} = Custode.Suggestions.dismiss("recent-agent", "cron", "@weekly")

      assert [first | _rest] = history()
      assert first.agent == "recent-agent"
    end

    test "an empty board is an empty record, not a crash" do
      assert history() == []
    end
  end
end
