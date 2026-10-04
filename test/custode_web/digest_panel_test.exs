defmodule CustodeWeb.DigestPanelTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias CustodeWeb.DigestPanel

  test "a quiet window has a short lead without an empty disclosure" do
    document = render_digest(quiet_digest())

    assert text(document, "h3") == "Fleet digest"
    assert text(document, "[data-digest-lead]") == "No turns recorded in this window."
    assert text(document, "[data-digest-panel]") =~ "last 7 days"
    assert nodes(document, "details") == []
    assert nodes(document, "[data-digest-section]") == []
  end

  test "a short digest describes turn success and keeps secondary spend closed" do
    digest = %{
      quiet_digest()
      | sweeps: %{total: 3, ok: 2, failed: 1, yield_pct: 67},
        failures: %{total: 1, by_kind: %{"max_turns" => 1}},
        spend: %{
          total_usd: 0.25,
          total_tokens: 1_200,
          by_agent: %{"worker" => %{usd: 0.25, tokens: 1_200}},
          by_model: %{}
        }
    }

    document = render_digest(digest)

    assert text(document, "[data-digest-lead]") ==
             "2 of 3 recorded turns succeeded (67%); 1 failed."

    assert length(nodes(document, "#digest-details")) == 1
    assert nodes(document, "details[open]") == []
    assert nodes(document, "[data-digest-remaining-spenders]") == []
    assert text(document, "[data-digest-section=failures]") =~ "max_turns"
    assert text(document, "[data-digest-section=spend]") =~ "$0.25"
    assert text(document, "[data-digest-section=spend]") =~ "1k tok"
    refute text(document, "[data-digest-panel]") =~ "yield"
    refute text(document, "[data-digest-panel]") =~ "work completed"
  end

  test "recorded anomalies stay in the lead even when every turn succeeded" do
    digest = %{
      quiet_digest()
      | sweeps: %{total: 1, ok: 1, failed: 0, yield_pct: 100},
        anomalies: ["worker: hit its daily budget rail and paused"]
    }

    document = render_digest(digest)

    assert text(document, "[data-digest-lead]") ==
             "1 of 1 recorded turn succeeded (100%); 0 failed. 1 anomaly recorded."

    assert nodes(document, "details[open]") == []
    assert text(document, "[data-digest-section=anomalies]") =~ "hit its daily budget rail"
  end

  test "long detail keeps every record in a stable order behind a closed disclosure" do
    evidence = String.duplicate("The scheduled run found the same result. ", 20)

    gates =
      for number <- 1..15 do
        %{
          agent: "gate-agent-#{number}",
          detail: "Reviewed **proposal #{number}**",
          status: "resolved",
          minutes: number
        }
      end

    suggestions =
      for number <- 1..20 do
        %{
          advisor: "cadence-advisor",
          agent: "suggestion-agent-#{number}",
          field: "cron",
          current: "@hourly",
          proposed: "@daily",
          confidence: "medium",
          evidence: "Record #{number}: " <> evidence
        }
      end

    digest = %{
      quiet_digest()
      | sweeps: %{total: 10, ok: 7, failed: 3, yield_pct: 70},
        anomalies: ["worker: **3 failed turns**", "worker: hit its daily budget rail"],
        failures: %{total: 3, by_kind: %{"timeout" => 2, "max_turns" => 1}},
        gates: %{count: 15, median_minutes: 8, recent: gates},
        suggestions: suggestions,
        spend: %{
          total_usd: 2.5,
          total_tokens: 3_000,
          by_agent: %{"worker" => %{usd: 2.5, tokens: 3_000}},
          by_model: %{"sonnet" => %{usd: 2.5, tokens: 3_000, turns: 10, failed: 3}}
        }
    }

    document = render_digest(digest)

    assert text(document, "[data-digest-lead]") =~ "2 anomalies recorded."

    assert attributes(document, "[data-digest-section]", "data-digest-section") ==
             ~w(anomalies failures gates suggestions spend)

    assert nodes(document, "details[open]") == []
    assert length(nodes(document, "[data-digest-section=gates] li")) == 15
    assert length(nodes(document, "[data-digest-section=suggestions] li")) == 20
    assert text(document, "[data-digest-section=gates]") =~ "Recent gate sample"
    assert text(document, "[data-digest-section=gates]") =~ "Recent resolutions shown: 15"
    assert text(document, "[data-digest-section=gates]") =~ "median 8 min"
    assert text(document, "[data-digest-section=gates] li:last-child") =~ "proposal 15"
    assert text(document, "[data-digest-section=suggestions]") =~ "Suggestion history"
    assert text(document, "[data-digest-section=suggestions]") =~ "may predate this window"
    assert text(document, "[data-digest-section=suggestions]") =~ "already have been acted on"
    assert text(document, "[data-digest-section=suggestions] li:last-child") =~ "Record 20:"

    assert text(document, "[data-digest-section=suggestions] li:last-child") =~
             String.trim(evidence)

    assert text(document, "[data-digest-section=spend] tbody") =~ "sonnet"
    assert text(document, "[data-digest-section=spend] tbody") =~ "10"
    assert text(document, "[data-digest-section=spend] tbody") =~ "$2.50"
    assert text(document, "[data-digest-section=spend] tbody") =~ "3k tok"
  end

  test "spenders rank by cost with stable ties and retain every remaining agent" do
    spenders = %{
      "zeta" => %{usd: 5.0, tokens: 60},
      "alpha" => %{usd: 5.0, tokens: 10},
      "beta" => %{usd: 4.0, tokens: 20},
      "gamma" => %{usd: 3.0, tokens: 30},
      "delta" => %{usd: 2.0, tokens: 40},
      "epsilon" => %{usd: 1.0, tokens: 50},
      "eta" => %{usd: 1.0, tokens: 70}
    }

    digest =
      put_in(quiet_digest(), [:spend], %{
        total_usd: 21.0,
        total_tokens: 280,
        by_agent: spenders,
        by_model: %{}
      })

    document = render_digest(digest)

    assert attributes(document, "[data-digest-top-spenders] > li", "data-digest-spender") ==
             ~w(alpha zeta beta gamma delta)

    assert attributes(
             document,
             "[data-digest-remaining-spenders] [data-digest-spender]",
             "data-digest-spender"
           ) ==
             ~w(epsilon eta)

    assert text(document, "[data-digest-remaining-spenders] summary") == "2 more agents"
    assert text(document, "[data-digest-remaining-spenders]") =~ "70 tok"
    assert nodes(document, "details[open]") == []

    assert attributes(document, "[data-digest-top-spenders] div[style]", "style") ==
             ["width: 100.0%", "width: 100.0%", "width: 80.0%", "width: 60.0%", "width: 40.0%"]
  end

  test "one remaining spender is described as one agent" do
    spenders = Map.new(1..6, fn number -> {"worker-#{number}", %{usd: 1.0, tokens: 0}} end)
    digest = put_in(quiet_digest(), [:spend, :by_agent], spenders)
    document = render_digest(digest)

    assert text(document, "[data-digest-remaining-spenders] summary") == "1 more agent"
  end

  test "zero-cost token spend remains visible without an invalid bar width" do
    digest =
      put_in(quiet_digest(), [:spend], %{
        total_usd: 0.0,
        total_tokens: 450,
        by_agent: %{"token-worker" => %{usd: 0.0, tokens: 450}},
        by_model: %{}
      })

    document = render_digest(digest)

    assert text(document, "[data-digest-section=spend]") =~ "450 tok"
    assert attributes(document, "[data-digest-top-spenders] div[style]", "style") == ["width: 0%"]
  end

  test "precise windows show the same relative time vocabulary and absolute timestamp" do
    since = DateTime.add(DateTime.utc_now(), -3_600, :second)
    digest = quiet_digest() |> Map.delete(:window_days) |> Map.put(:since, since)
    document = render_digest(digest)

    assert text(document, "[data-digest-panel]") =~ "since 1h ago"
    assert attributes(document, "span[title]", "title") == [DateTime.to_iso8601(since)]
    refute text(document, "[data-digest-panel]") =~ "last 7 days"

    document = render_digest(Map.put(digest, :window_days, 1))
    assert text(document, "[data-digest-panel]") =~ "last 1 day"
  end

  test "agent prose uses safe Markdown while record fields remain inert" do
    prose =
      "Read **the evidence** and `details`. <script>alert(1)</script> [unsafe](javascript:alert(1))"

    digest = %{
      quiet_digest()
      | anomalies: [prose],
        gates: %{
          count: 1,
          median_minutes: 2,
          recent: [
            %{
              agent: "<img src=x onerror=alert(1)>",
              detail: prose,
              status: "resolved",
              minutes: 2
            }
          ]
        },
        suggestions: [
          %{
            advisor: "advisor",
            agent: "worker",
            field: "cron",
            current: nil,
            proposed: "<svg onload=alert(1)>",
            confidence: nil,
            evidence: prose
          }
        ]
    }

    document = render_digest(digest)

    assert length(nodes(document, "strong")) == 3
    assert text(document, "[data-digest-section=suggestions]") =~ "(none)"
    assert text(document, "[data-digest-section=suggestions]") =~ "<svg onload=alert(1)>"
    assert text(document, "[data-digest-section=anomalies]") =~ "<script>alert(1)</script>"
    assert nodes(document, "script, img, svg, [onerror], [onload]") == []
    assert nodes(document, "a[href^='javascript:']") == []
  end

  defp quiet_digest do
    %{
      window_days: 7,
      spend: %{total_usd: 0.0, total_tokens: 0, by_agent: %{}, by_model: %{}},
      sweeps: %{total: 0, ok: 0, failed: 0, yield_pct: 0},
      gates: %{count: 0, median_minutes: 0, recent: []},
      failures: %{total: 0, by_kind: %{}},
      suggestions: [],
      anomalies: []
    }
  end

  defp render_digest(digest) do
    render_component(&DigestPanel.digest_panel/1, id: "digest", digest: digest)
    |> LazyHTML.from_document()
  end

  defp nodes(document, selector), do: document |> LazyHTML.query(selector) |> Enum.to_list()

  defp text(document, selector),
    do: document |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp attributes(document, selector, attribute) do
    document
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, attribute))
  end
end
