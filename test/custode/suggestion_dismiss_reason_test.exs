defmodule Custode.SuggestionDismissReasonTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Custode.Feed
  alias Custode.Suggestions

  @endpoint CustodeWeb.Endpoint

  setup do
    path = Path.join(System.tmp_dir!(), uid("dismiss") <> ".jsonl")
    put_env!(:feed_path, path)
    on_exit(fn -> File.rm(path) end)

    on_exit(fn ->
      Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'advisor_%'")
    end)

    Custode.Repo.query!("DELETE FROM feed_entries WHERE event LIKE 'advisor_%'")

    workspace = tmp_workspace!()
    routine = routine_fixture!(workspace)
    %{conn: build_conn(), routine: routine}
  end

  defp suggest!(agent, field, proposed) do
    Feed.record(%{
      event: "advisor_suggestion",
      agent: agent,
      advisor: "advisor-cadence",
      field: field,
      current: "@daily",
      proposed: proposed,
      evidence: "9 of 6 daily sweeps yielded"
    })
  end

  describe "dismiss/4" do
    test "records the reason on the entry", %{routine: routine} do
      suggest!(routine.id, "cron", "*/30 9-18 * * *")

      {:ok, message} =
        Suggestions.dismiss(routine.id, "cron", "*/30 9-18 * * *", "not_now")

      assert message =~ "right, but not now"

      [entry | _rest] = Feed.recent_by_event("advisor_dismissed", limit: 1)
      assert entry["reason"] == "not_now"
      assert entry["summary"] =~ "right, but not now"
    end

    test "a reasonless dismissal still works, and says nothing extra", %{routine: routine} do
      {:ok, message} = Suggestions.dismiss(routine.id, "cron", "@weekly")

      assert message =~ "dismissed"
      refute message =~ "--"

      [entry | _rest] = Feed.recent_by_event("advisor_dismissed", limit: 1)
      assert entry["reason"] == nil
    end

    test "an unknown reason key is recorded but not dressed up as a label",
         %{routine: routine} do
      {:ok, message} = Suggestions.dismiss(routine.id, "cron", "@weekly", "nonsense")

      # the key survives for the record; only known keys get a human label
      refute message =~ "nonsense"

      assert [%{"reason" => "nonsense"} | _rest] =
               Feed.recent_by_event("advisor_dismissed", limit: 1)
    end

    test "dismissing still masks the suggestion for the window", %{routine: routine} do
      suggest!(routine.id, "cron", "*/30 9-18 * * *")
      assert Enum.any?(Suggestions.standing(), &(&1["agent"] == routine.id))

      {:ok, _message} = Suggestions.dismiss(routine.id, "cron", "*/30 9-18 * * *", "disagree")
      refute Enum.any?(Suggestions.standing(), &(&1["agent"] == routine.id))
    end
  end

  describe "dismiss_reasons/0" do
    test "offers the three distinct answers, not a severity scale" do
      keys = Suggestions.dismiss_reasons() |> Enum.map(&elem(&1, 0))
      assert keys == ["wrong_evidence", "not_now", "disagree"]
    end

    test "labels round-trip, and an unknown key has none" do
      assert Suggestions.dismiss_reason_label("not_now") == "right, but not now"
      assert Suggestions.dismiss_reason_label("nope") == nil
    end
  end

  describe "the suggestions page" do
    test "dismiss asks why, and records the answer", %{conn: conn, routine: routine} do
      suggest!(routine.id, "cron", "*/30 9-18 * * *")

      {:ok, view, html} = live(conn, "/suggestions")

      # the common path stays one click: the reasons are not on the card yet
      assert html =~ "dismiss"
      refute html =~ "right, but not now"

      html = view |> element("button", "dismiss") |> render_click()
      assert html =~ "why?"
      assert html =~ "right, but not now"

      view |> element("button", "right, but not now") |> render_click()

      [entry | _rest] = Feed.recent_by_event("advisor_dismissed", limit: 1)
      assert entry["reason"] == "not_now"
    end

    test "cancel backs out without recording anything", %{conn: conn, routine: routine} do
      suggest!(routine.id, "cron", "*/30 9-18 * * *")

      {:ok, view, _html} = live(conn, "/suggestions")
      view |> element("button", "dismiss") |> render_click()
      html = view |> element("button", "cancel") |> render_click()

      refute html =~ "why?"
      assert Feed.recent_by_event("advisor_dismissed", limit: 1) == []
    end
  end
end
