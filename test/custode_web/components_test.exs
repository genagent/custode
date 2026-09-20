defmodule CustodeWeb.ComponentsTest do
  use ExUnit.Case, async: true

  import CustodeWeb.Components

  describe "usd/1" do
    test "always two decimals" do
      assert usd(7.6782) == "7.68"
      assert usd(20.089) == "20.09"
      assert usd(25.0) == "25.00"
      assert usd(0) == "0.00"
    end
  end

  describe "the ask pair in the feed vocabulary (#445)" do
    test "an asked entry is an attention event, styled below a blocking question" do
      assert feed_category_match?("asked", "attention")
      assert feed_badge("asked") =~ "badge-accent"
      assert feed_badge("asked") =~ "badge-outline"
      refute feed_badge("needs_input") =~ "badge-outline"
      assert event_dot("asked") == "text-accent"
    end

    test "an answered entry is the operator's act, not something waiting on them" do
      refute feed_category_match?("answered", "attention")
      assert feed_badge("answered") =~ "badge-success"
      assert event_dot("answered") == "text-success"
    end
  end

  describe "a failed sensor run in the feed vocabulary (#444)" do
    test "it is drawn as an error, not in the ambient grey of a quiet sensor line" do
      assert feed_badge("sensor_failed") == "badge-error"
      assert event_dot("sensor_failed") == "text-error"
      assert feed_badge("sensor") == "badge-ghost"
    end

    test "it shows under both the attention lens and the sensors lens" do
      assert feed_category_match?("sensor_failed", "attention")
      assert feed_category_match?("sensor_failed", "sensors")
      refute feed_category_match?("sensor", "attention")
    end
  end

  describe "ago_text/1" do
    test "buckets seconds/minutes/hours/days and tolerates junk" do
      now = DateTime.utc_now()
      assert ago_text(DateTime.add(now, -5)) == "5s ago"
      assert ago_text(DateTime.add(now, -300)) == "5m ago"
      assert ago_text(DateTime.add(now, -7200)) == "2h ago"
      assert ago_text(DateTime.add(now, -172_800)) == "2d ago"
      assert ago_text(DateTime.add(now, -90) |> DateTime.to_iso8601()) == "1m ago"
      assert ago_text("not a time") == "not a time"
      assert ago_text(nil) == "?"
    end
  end

  describe "until_text/2" do
    test "buckets the wait, and a time already past is now" do
      now = ~U[2026-09-20 10:00:00Z]
      assert until_text(DateTime.add(now, 40), now) == "40s"
      assert until_text(DateTime.add(now, 720), now) == "12m"
      assert until_text(DateTime.add(now, 3 * 3_600 + 59), now) == "3h"
      assert until_text(DateTime.add(now, 2 * 86_400), now) == "2d"
      assert until_text(now, now) == "now"
      assert until_text(DateTime.add(now, -30), now) == "now"
    end
  end

  describe "markdown rendering" do
    import Phoenix.LiveViewTest, only: [render_component: 2]

    test "tables and code render; raw HTML from agents is inert" do
      table = "| repo | license |\n|------|---------|\n| adrs | Apache-2.0 |"
      html = render_component(&CustodeWeb.Components.markdown/1, text: table)
      assert html =~ "<table"
      assert html =~ "Apache-2.0"

      sneaky = "hello <script>alert(1)</script> `code` world"
      html = render_component(&CustodeWeb.Components.markdown/1, text: sneaky)
      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;" or html =~ "&amp;lt;script"
      assert html =~ "<code"
    end
  end

  describe "feed_text/1" do
    test "failure events carry a what-happens-next hint" do
      assert feed_text(%{"event" => "turn_failed", "kind" => "max_turns_exceeded"}) =~
               "re-approving grants a fresh turn budget"

      assert feed_text(%{"event" => "turn_failed", "kind" => "max_budget_exceeded"}) =~
               "max_budget_usd"

      assert feed_text(%{"event" => "turn_failed", "kind" => "timeout"}) =~ "timeout_ms"
      assert feed_text(%{"event" => "turn_failed", "kind" => "weird"}) =~ "next beat retries"
    end

    test "budget_paused explains the rail and the exit" do
      assert feed_text(%{"event" => "budget_paused"}) =~ "human resumes"
    end

    test "ordinary events keep the summary-first fallback chain" do
      assert feed_text(%{"event" => "turn", "summary" => "swept"}) == "swept"
      assert feed_text(%{"event" => "needs_approval", "action" => "rm"}) == "rm"
    end
  end
end
