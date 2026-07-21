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
