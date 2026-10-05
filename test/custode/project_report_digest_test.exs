defmodule Custode.ProjectReportDigestTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

  alias Custode.{Feed, ProjectReportDigest, Repo}
  alias Custode.MCP.CallContext, as: Frame
  alias Custode.MCP.ProjectReportDigestTools.Read

  @endpoint CustodeWeb.Endpoint
  @operator %{kind: :operator, id: "operator"}

  setup do
    clear_attention!()
    caretaker = uid("digest-caretaker")
    claude = uid("digest-claude")
    codex = uid("digest-codex")
    ids = [caretaker, claude, codex]
    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{
        id: caretaker,
        role: :caretaker,
        provider: :claude,
        cron: :manual,
        workspace: workspace,
        prompt: "manage"
      },
      %{
        id: claude,
        role: :backlog_worker,
        provider: :claude,
        cron: :manual,
        workspace: workspace,
        prompt: "work"
      },
      %{
        id: codex,
        role: :specialist,
        provider: :codex,
        cron: :manual,
        workspace: workspace,
        prompt: "work"
      }
    ])

    on_exit(fn ->
      Repo.delete_all(from(f in Feed.Entry, where: f.agent in ^ids))
      Repo.delete_all(from(a in Custode.Asks.Ask, where: a.agent_id in ^ids))
      Repo.delete_all(from(g in Custode.Gates.Gate, where: g.agent_id in ^ids))
      Repo.delete_all(from(s in Custode.AgentAuthorizationSnapshot, where: s.routine_id in ^ids))
    end)

    %{
      caretaker: caretaker,
      claude: claude,
      codex: codex,
      now: DateTime.utc_now()
    }
  end

  test "both providers expose durable authored updates and separate current decisions", ctx do
    report = %{"done" => ["Saved findings."], "verified" => ["Checks reported; CI unknown."]}
    a = row!(ctx.claude, ctx.now, %{report: report, provider: "claude", turn_id: "claude-turn"})
    b = row!(ctx.codex, ctx.now, %{report: report, provider: "codex", turn_id: "codex-turn"})

    for actor <- [@operator, %{kind: :routine, id: ctx.caretaker}] do
      assert {:ok, digest} = ProjectReportDigest.read(actor, now: ctx.now)
      assert digest.schema_version == "custode.project_report_digest.v1"
      assert digest.coverage.configured_projects == 3
      assert project(digest, ctx.claude).reports |> hd() |> Map.fetch!(:id) == a.id
      assert project(digest, ctx.codex).reports |> hd() |> Map.fetch!(:id) == b.id

      assert project(digest, ctx.codex).reports |> hd() |> Map.fetch!(:provenance) == %{
               "provider" => "codex",
               "turn_id" => "codex-turn"
             }

      assert project(digest, ctx.claude).reports |> hd() |> Map.fetch!(:evidence) ==
               "agent_authored"

      refute Map.has_key?(digest, :accepted)
      assert project(digest, ctx.caretaker).freshness.state == "missing"
      assert project(digest, ctx.claude).execution.applied == nil
      assert {:ok, repeated} = ProjectReportDigest.read(actor, now: ctx.now)
      assert repeated == digest
    end

    assert Repo.get!(Feed.Entry, a.id) == a
  end

  test "window endpoints are inclusive and future rows cannot relabel freshness", ctx do
    since = DateTime.add(ctx.now, -3600)
    old = row!(ctx.claude, DateTime.add(since, -1), %{summary: "outside"})
    first = row!(ctx.claude, since, %{summary: "boundary"})
    last = row!(ctx.claude, ctx.now, %{summary: "latest"})
    row!(ctx.claude, DateTime.add(ctx.now, 1), %{summary: "future"})

    assert {:ok, digest} =
             ProjectReportDigest.read(@operator, now: ctx.now, window_hours: 1, report_limit: 3)

    project = project(digest, ctx.claude)
    assert Enum.map(project.reports, & &1.id) == [last.id, first.id]
    refute old.id in Enum.map(project.reports, & &1.id)
    assert project.freshness.latest_recorded_at == DateTime.to_iso8601(ctx.now)
    assert project.freshness.within_window
  end

  test "old typed concerns and current unanswered rows survive an empty report window", ctx do
    old = DateTime.add(ctx.now, -72 * 3600)

    row!(ctx.claude, old, %{
      report: %{"blockers" => ["Upstream release needed."], "decisions" => ["Choose a policy."]}
    })

    ask =
      Repo.insert!(%Custode.Asks.Ask{
        agent_id: ctx.claude,
        question: "Approve the scope?",
        status: "open",
        inserted_at: old,
        updated_at: old
      })

    gate =
      Repo.insert!(%Custode.Gates.Gate{
        agent_id: ctx.claude,
        action_id: uid("gate"),
        kind: "approval",
        detail: "Ready to publish",
        status: "open",
        inserted_at: old,
        updated_at: old
      })

    assert {:ok, digest} = ProjectReportDigest.read(@operator, now: ctx.now)
    project = project(digest, ctx.claude)
    assert project.reports == []
    assert project.freshness.state == "stale"
    assert project.reported_concerns.blockers == ["Upstream release needed."]
    assert project.reported_concerns.resolution == "not established"
    assert [%{id: ask_id, blocking: false}] = project.decisions.asks
    assert ask_id == ask.id
    assert [%{id: gate_id, blocking: true}] = project.decisions.gates
    assert gate_id == gate.id
    assert Repo.get!(Custode.Asks.Ask, ask.id).status == "open"
    assert Repo.get!(Custode.Gates.Gate, gate.id).status == "open"
  end

  test "legacy, invalid and failed reports keep truthful recorded behavior", ctx do
    old = DateTime.add(ctx.now, -2)
    row!(ctx.claude, old, %{report: %{"accepted" => true}})
    failed = row!(ctx.claude, ctx.now, %{event: "turn_failed", summary: "Permission refused."})
    assert {:ok, digest} = ProjectReportDigest.read(@operator, now: ctx.now, report_limit: 3)
    [failure, invalid] = project(digest, ctx.claude).reports
    assert failure.id == failed.id
    assert failure.event == "turn_failed"
    assert failure.report == nil
    assert failure.summary == "Permission refused."
    assert invalid.report == nil
    assert invalid.report_error =~ "report"
    assert project(digest, ctx.claude).reported_concerns == nil
  end

  test "limits are explicit, deterministic and reject unsupported bounds", ctx do
    for n <- 1..4, do: row!(ctx.claude, ctx.now, %{summary: "update #{n}"})

    for _n <- 1..4,
        do:
          Repo.insert!(%Custode.Asks.Ask{
            agent_id: ctx.claude,
            question: "Pending",
            status: "open"
          })

    assert {:ok, digest} = ProjectReportDigest.read(@operator, now: ctx.now, project_limit: 1)
    assert digest.coverage.has_more_projects
    assert digest.coverage.shown_projects == 1
    assert {:ok, all} = ProjectReportDigest.read(@operator, now: ctx.now, report_limit: 2)
    assert length(project(all, ctx.claude).reports) == 2
    assert project(all, ctx.claude).has_more_reports
    assert length(project(all, ctx.claude).decisions.asks) == 3
    assert project(all, ctx.claude).decisions.has_more_asks

    for opts <- [
          [window_hours: 0],
          [window_hours: 169],
          [project_limit: 51],
          [report_limit: 4],
          [report_limit: "2"],
          [now: nil],
          [bogus: true],
          [report_limit: 1, report_limit: 2]
        ] do
      assert {:error, _} = ProjectReportDigest.read(@operator, opts)
    end
  end

  test "workers and unverified callers are refused before observing reports", ctx do
    row!(ctx.claude, ctx.now, %{summary: "private owner report"})

    for actor <- [
          %{},
          nil,
          %{kind: :operator},
          %{kind: :routine, id: ""},
          %{kind: :routine, id: ctx.claude},
          %{kind: :sub_agent, id: ctx.caretaker}
        ] do
      assert {:error, error} = ProjectReportDigest.read(actor)
      assert is_binary(error)
      refute error =~ "private owner report"
      assert Read.execute(%{}, %Frame{assigns: %{custode_identity: actor}}) |> tool_error() != ""
    end

    assert Read.execute(%{}, %Frame{assigns: %{custode_identity: @operator}})
           |> tool_json()
           |> Map.fetch!("schema_version") == "custode.project_report_digest.v1"

    assert Read.execute(%{window_hours: 0}, %Frame{assigns: %{custode_identity: @operator}})
           |> tool_error() =~ "window_hours"
  end

  test "manager shows the shared digest and refreshes other owners' reports", ctx do
    row!(ctx.codex, DateTime.add(ctx.now, -1), %{
      summary: "Prepared the comparison.",
      report: %{"done" => ["Compared two options."]}
    })

    {:ok, view, html} = live(build_conn(), "/custode")
    assert html =~ "Project digest"
    assert has_element?(view, "#project-report-digest", "Compared two options.")
    assert has_element?(view, ~s(a[href="/agents/#{ctx.codex}/conversation"]))
    assert has_element?(view, "#project-report-freshness", "missing")
    Custode.Feed.record(%{event: "turn", agent: ctx.claude, summary: "New findings ready."})
    assert render(view) =~ "New findings ready."
    {:ok, _, refreshed} = live(build_conn(), "/custode")
    assert refreshed =~ "New findings ready."
    refute html =~ "accepted automatically"
  end

  test "manager digest folds long retained summaries and decisions without losing source text",
       ctx do
    summary =
      String.duplicate("A dated finding with its source remains available. ", 12) |> String.trim()

    blocker =
      String.duplicate("Waiting for the upstream compatibility release. ", 9) |> String.trim()

    decision =
      String.duplicate("Choose the next bounded project comparison. ", 9) |> String.trim()

    assert {:ok, _} =
             Custode.IntervalReports.validate(%{
               "blockers" => [blocker],
               "decisions" => [decision]
             })

    row =
      row!(ctx.codex, DateTime.add(ctx.now, -1), %{
        summary: summary,
        report: %{"blockers" => [blocker], "decisions" => [decision]}
      })

    short = row!(ctx.claude, ctx.now, %{summary: "A short update."})

    ask =
      Repo.insert!(%Custode.Asks.Ask{
        agent_id: ctx.codex,
        question: decision,
        status: "open"
      })

    {:ok, view, _html} = live(build_conn(), "/custode")

    refute has_element?(view, "#project-report-digest[open]")
    assert has_element?(view, "#project-report-digest-summary", "Project digest")
    assert has_element?(view, ~s(a[href="#project-report-digest"][phx-click]))

    for {id, text} <- [
          {"project-digest-summary-#{row.id}", summary},
          {"project-digest-concern-#{row.id}-blocker-0", blocker},
          {"project-digest-concern-#{row.id}-decision-0", decision},
          {"project-digest-ask-#{ask.id}", decision}
        ] do
      assert has_element?(view, "##{id}-disclosure[phx-hook=DisclosureState]")
      refute has_element?(view, "##{id}-disclosure[open]")
      assert has_element?(view, "##{id} [data-foldable-full]", text)
    end

    assert has_element?(view, "#project-digest-summary-#{short.id}", "A short update.")
    refute has_element?(view, "#project-digest-summary-#{short.id}-disclosure")

    Custode.Feed.record(%{event: "turn", agent: ctx.claude, summary: "Fresh owner update."})
    assert render(view) =~ "Fresh owner update."

    assert has_element?(
             view,
             "#project-digest-summary-#{row.id}-disclosure [data-foldable-full]",
             summary
           )

    assert has_element?(
             view,
             "#project-digest-ask-#{ask.id}-disclosure [data-foldable-full]",
             decision
           )

    assert :offline = Custode.Agents.live_provider(ctx.codex)
  end

  test "duplicate completion ingestion stays one digest record", ctx do
    key = uid("digest-completion")
    entry = %{agent: ctx.claude, summary: "Finished once.", report: %{"done" => ["One result."]}}
    assert :ok = Feed.record_turn(entry, key)
    assert :ok = Feed.record_turn(entry, key)
    assert {:ok, digest} = ProjectReportDigest.read(@operator, report_limit: 3)
    assert [%{summary: "Finished once."}] = project(digest, ctx.claude).reports
  end

  defp project(digest, id), do: Enum.find(digest.projects, &(&1.owner == id))

  defp row!(id, at, attrs) do
    entry =
      Map.merge(
        %{agent: id, event: "turn", at: DateTime.to_iso8601(at), summary: "Owner update."},
        attrs
      )

    Repo.insert!(%Feed.Entry{agent: id, event: entry.event, at: at, entry: Jason.encode!(entry)})
  end
end
