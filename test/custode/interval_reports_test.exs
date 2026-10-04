defmodule Custode.IntervalReportsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Custode.{Feed, IntervalReports}
  alias Custode.Feed.Ingest

  test "report limits are enforced without interpreting verification as acceptance" do
    assert {:ok, nil} = IntervalReports.validate(nil)
    assert {:ok, empty} = IntervalReports.validate(%{})
    assert Enum.all?(empty, fn {_key, entries} -> entries == [] end)

    report = %{
      "done" => ["Saved findings."],
      "verified" => ["CI not run; fixture checks passed."]
    }

    assert {:ok, validated} = IntervalReports.validate(report)
    assert validated["verified"] == report["verified"]
    refute Map.has_key?(validated, "accepted")

    for invalid <- [
          false,
          [],
          %{"accepted" => true},
          %{"done" => [" "]},
          %{"done" => ["a", "b", "c", "d"]},
          %{"next" => [String.duplicate("a", 501)]},
          %{"verified" => [123]}
        ] do
      assert {:error, error} = IntervalReports.validate(invalid)
      assert error =~ "report"
    end

    assert {:ok, _} = IntervalReports.validate(%{"next" => [String.duplicate("é", 500)]})
  end

  test "both providers persist reports with exact provenance, once per execution attempt" do
    Custode.PubSubBridge.subscribe()

    for provider <- [:oban_claude, :oban_codex] do
      agent = uid("interval")

      job = %Oban.Job{
        id: System.unique_integer([:positive]),
        attempt: 1,
        meta: %{
          "agent_id" => agent,
          "origin" => "operator",
          "correlation_id" => "operator:exact",
          "config_revision" => "revision-at-launch",
          "agent_generation" => "generation",
          "agent_turn_id" => "turn"
        }
      }

      out = %{
        "directive" => "none",
        "summary" => "Saved research.",
        "report" => %{
          "done" => ["Saved [findings](https://example.com/findings)."],
          "verified" => ["Source checked; downstream review pending."],
          "next" => ["Wait for review."]
        }
      }

      result = result(provider, out)
      meta = %{job: job, result: result}
      event = [provider, :run, :stop]
      measurements = %{cost_usd: 0.1}
      assert :ok = Ingest.handle_event(event, measurements, meta, nil)
      assert_receive {:feed_entry, %{"agent" => ^agent}}
      assert :ok = Ingest.handle_event(event, measurements, meta, nil)
      refute_receive {:feed_entry, %{"agent" => ^agent}}
      assert [entry] = Feed.for_agent(agent)
      assert entry["report"]["done"] == out["report"]["done"]
      assert entry["correlation_id"] == "operator:exact"
      assert entry["config_revision"] == "revision-at-launch"
      assert entry["job_id"] == job.id
      assert entry["job_attempt"] == 1
      assert entry["origin"] == "operator"
      assert entry["provider"] in ["claude", "codex"]

      assert :ok =
               Ingest.handle_event(event, measurements, %{meta | job: %{job | attempt: 2}}, nil)

      assert length(Feed.for_agent(agent)) == 2
      recent = IntervalReports.recent(agent, 1)
      assert [%{"job_attempt" => 2, "id" => id}] = recent.entries
      assert is_integer(id)
      assert recent.latest_at != nil
      assert recent.evidence == "agent_authored"
    end
  end

  test "concurrent duplicate completions preserve one durable row" do
    agent = uid("concurrent-report")
    key = uid("completion")
    entry = %{event: "turn", agent: agent, summary: "One completion."}

    results =
      1..8
      |> Task.async_stream(fn _ -> Feed.record_turn(entry, key) end, max_concurrency: 8)
      |> Enum.to_list()

    assert Enum.all?(results, &(&1 == {:ok, :ok}))
    assert [%{"summary" => "One completion."}] = Feed.for_agent(agent)
  end

  test "a failed provider run never publishes its proposed success report" do
    agent = uid("failed-report")

    success =
      result(:oban_claude, %{
        "directive" => "none",
        "summary" => "Claimed success.",
        "report" => %{"done" => ["Not trustworthy."]}
      })

    failed = %{success | is_error: true}
    meta = %{job: %Oban.Job{meta: %{"agent_id" => agent}}, result: failed}
    Ingest.handle_event([:oban_claude, :run, :stop], %{cost_usd: 0.0}, meta, nil)
    assert [%{"event" => "turn_failed"} = entry] = Feed.for_agent(agent)
    refute Map.has_key?(entry, "report")
    assert IntervalReports.recent(agent).entries == []
  end

  test "invalid reports retain summary, directive and original answer with a visible diagnostic" do
    agent = uid("invalid-report")

    out = %{
      "directive" => "request_permission",
      "summary" => "Need permission.",
      "action_class" => "implement",
      "report" => %{"done" => [String.duplicate("x", 501)]}
    }

    meta = %{
      job: %Oban.Job{meta: %{"agent_id" => agent, "origin" => "operator"}},
      result: result(:oban_claude, out)
    }

    Ingest.handle_event([:oban_claude, :run, :stop], %{cost_usd: 0.0}, meta, nil)
    assert [entry] = Feed.for_agent(agent)
    assert entry["summary"] == "Need permission."
    assert entry["directive"] == "request_permission"
    assert entry["action_class"] == "implement"
    assert entry["report_error"] =~ "report.done"
    refute Map.has_key?(entry, "report")
    html = render_component(&CustodeWeb.Components.feed_entry/1, entry: entry)
    assert html =~ "Report unavailable"
    assert html =~ "Need permission."
  end

  test "legacy turns remain summary-only and report rendering preserves links safely" do
    agent = uid("legacy-report")
    Feed.record(%{event: "turn", agent: agent, summary: "Nothing changed."})
    Feed.record(%{event: "sensor", agent: agent, summary: "Not a report."})
    assert [%{"summary" => "Nothing changed."} = legacy] = IntervalReports.recent(agent).entries
    refute Map.has_key?(legacy, "provider")
    refute Map.has_key?(legacy, "report")

    {:ok, report} =
      IntervalReports.validate(%{
        "done" => ["Read [evidence](https://example.com)."],
        "verified" => ["<script>alert(1)</script>"]
      })

    html = render_component(&CustodeWeb.Components.interval_report/1, report: report)
    assert html =~ "Done"
    assert html =~ "Verified"
    assert html =~ "https://example.com"
    refute html =~ ">Next<"
    refute html =~ "<script>"
  end

  defp result(:oban_claude, out), do: ObanClaude.Testing.structured_result(out)
  defp result(:oban_codex, out), do: ObanCodex.Testing.structured_result(out)
end
