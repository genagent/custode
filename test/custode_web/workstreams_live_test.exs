defmodule CustodeWeb.WorkstreamsLiveTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query, only: [from: 2]

  alias Custode.{Feed, Repo, WorkAgreements}

  @endpoint CustodeWeb.Endpoint
  @human %{kind: :operator, id: "dashboard-test-human"}

  setup do
    clear_attention!()
    put_env!(:sensors, [])
    workspace = tmp_workspace!()

    ids = %{
      software: uid("widgets"),
      research: uid("coastal-research"),
      quiet: uid("maintenance")
    }

    routines =
      for {kind, id} <- ids do
        %{
          id: id,
          cron: "@daily",
          workspace: workspace,
          prompt: "Maintain this domain",
          role: :assistant,
          repo: if(kind == :software, do: "example/widgets"),
          on_note: :ignore
        }
      end

    put_env!(:routines, routines)

    on_exit(fn ->
      owners = Map.values(ids)

      agreements =
        Repo.all(
          from(a in "work_agreements", where: a.routine_id in ^owners, select: a.agreement_id)
        )

      Repo.delete_all(from(r in "work_agreement_records", where: r.agreement_id in ^agreements))
      Repo.delete_all(from(a in "work_agreements", where: a.routine_id in ^owners))
      Repo.delete_all(from(f in Feed.Entry, where: f.agent in ^owners))
      Repo.delete_all(from(a in Custode.Asks.Ask, where: a.agent_id in ^owners))
      Repo.delete_all(from(g in Custode.Gates.Gate, where: g.agent_id in ^owners))
    end)

    %{ids: ids, conn: build_conn()}
  end

  test "home is compact, read-only and keeps the PM and control room reachable", ctx do
    agreement!(ctx.ids.software, "Ship a bounded parser fix")

    report!(ctx.ids.software, "Parser fix reported ready", %{
      "next" => ["Maybe rewrite the parser"]
    })

    {:ok, _ask} = Custode.Asks.ask(ctx.ids.research, "Which coast should I investigate?")
    before = counts()

    {:ok, view, _html} = live(ctx.conn, "/")
    assert has_element?(view, "#workstream-home")
    assert has_element?(view, "#application-header a[aria-current=page]", "Dashboard")
    assert has_element?(view, ~s(a[href="/custode"]), "PM conversation")
    assert has_element?(view, ~s(a[href="/console"]))
    assert has_element?(view, "#workstream-attention", "Which coast should I investigate?")

    assert has_element?(
             view,
             "[data-workstream-owner='#{ctx.ids.software}']",
             "Ship a bounded parser fix"
           )

    assert has_element?(view, "[data-workstream-owner='#{ctx.ids.quiet}']")
    refute has_element?(view, "form[phx-submit]")
    refute has_element?(view, "#workstream-diagnostics")
    assert counts() == before

    view
    |> element(~s(a[href="/workstreams/#{ctx.ids.software}"]), "Open workstream")
    |> render_click()

    assert_patch(view, "/workstreams/#{ctx.ids.software}")
    assert has_element?(view, "#workstream-detail[data-workstream-owner='#{ctx.ids.software}']")
    assert has_element?(view, ~s(a[href="/agents/#{ctx.ids.software}/conversation"]))
    assert counts() == before
  end

  test "detail distinguishes accepted research, recorded steps and reported suggestions", ctx do
    id = agreement!(ctx.ids.research, "Determine whether off-season ferry travel is feasible")

    checkpoint!(
      id,
      "Check winter timetables",
      "Operator must supply dates; comparison cannot proceed"
    )

    {:ok, submitted} =
      WorkAgreements.submit(@human, id, %{
        request_id: uid("submit"),
        agreement_revision: 1,
        assignment_id: "bounded-assignment",
        summary: "No supported ferry route was found for the proposed dates",
        outputs: [],
        criterion_evidence: [
          %{
            criterion_id: "evidence",
            references: [%{kind: "document", value: "findings.md"}],
            note: "The source does not establish winter availability"
          }
        ],
        verification_limits: "Timetables may change; no booking was made"
      })

    {:ok, _} =
      WorkAgreements.resolve(@human, id, %{
        request_id: uid("resolve"),
        expected_revision: 1,
        submission_id: submitted["record_id"],
        outcome: "accepted",
        reason: "A negative finding answers the current question"
      })

    report!(ctx.ids.research, "Saved a negative research finding", %{
      "done" => ["Compared the available sources"],
      "verified" => ["Agent reports checking two sources"],
      "next" => ["Maybe research rail travel instead"]
    })

    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.research}")
    assert has_element?(view, "#workstream-done", "No supported ferry route")
    assert has_element?(view, "#workstream-done", "accepted")
    assert has_element?(view, "#workstream-done", "Timetables may change")
    assert has_element?(view, "#workstream-done", "findings.md")
    refute has_element?(view, "#workstream-todo", "Check winter timetables")
    refute has_element?(view, "#workstream-blockers", "Operator must supply dates")

    follow_up = agreement!(ctx.ids.research, "Investigate a separate transport alternative")

    checkpoint!(
      follow_up,
      "Check winter timetables",
      "Operator must supply dates; comparison cannot proceed"
    )

    send(view.pid, {:work_agreement_changed, ctx.ids.research})
    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-todo", "Check winter timetables")
    refute has_element?(view, "#workstream-todo", "Maybe research rail travel instead")
    assert render(view) =~ "Maybe research rail travel instead"
    assert has_element?(view, "#workstream-blockers", "Operator must supply dates")
    assert has_element?(view, "#workstream-blockers", "operator")
    assert has_element?(view, "#workstream-doing", "bounded-assignment")
    assert has_element?(view, "#workstream-diagnostics")
    refute has_element?(view, "#workstream-diagnostics[open]")
  end

  test "stale and absent reports do not become proof of inactivity", ctx do
    report!(
      ctx.ids.software,
      "Old retained update",
      %{},
      DateTime.add(DateTime.utc_now(), -72 * 3600)
    )

    {:ok, view, _} = live(ctx.conn, "/")
    assert has_element?(view, "[data-workstream-owner='#{ctx.ids.software}']", "stale")
    assert has_element?(view, "[data-workstream-owner='#{ctx.ids.quiet}']", "missing")
    assert render(view) =~ "inactivity"
    {:ok, detail, _} = live(ctx.conn, "/workstreams/#{ctx.ids.quiet}")
    assert has_element?(detail, "#workstream-purpose", "No")
    assert has_element?(detail, "#workstream-todo", "No")
    refute has_element?(detail, "form[phx-submit]")
  end

  test "the same open question disappears after its underlying record is answered", ctx do
    {:ok, ask} = Custode.Asks.ask(ctx.ids.software, "Which release is the target?")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.software}")
    assert has_element?(view, "#workstream-decisions", "Which release is the target?")
    ask |> Ecto.Changeset.change(status: "answered", answer: "The next release") |> Repo.update!()
    send(view.pid, {:status_changed, ctx.ids.software})
    send(view.pid, :refresh)
    refute has_element?(view, "#workstream-decisions", "Which release is the target?")
    refute has_element?(view, "#workstream-attention", "Which release is the target?")
  end

  test "bounded agreement coverage never claims older open work is absent", ctx do
    older = agreement!(ctx.ids.software, "Older active assignment")
    checkpoint!(older, "Older committed step", "Older unresolved blocker")

    for n <- 1..3 do
      id = agreement!(ctx.ids.software, "Newer reviewed assignment #{n}")

      {:ok, submission} =
        WorkAgreements.submit(@human, id, %{
          request_id: uid("bounded-submit"),
          agreement_revision: 1,
          assignment_id: "bounded-assignment",
          summary: "Reviewed outcome #{n}",
          criterion_evidence: [
            %{criterion_id: "evidence", references: [], note: "No further source available"}
          ],
          verification_limits: "No independent verification"
        })

      {:ok, _} =
        WorkAgreements.resolve(@human, id, %{
          request_id: uid("bounded-resolve"),
          expected_revision: 1,
          submission_id: submission["record_id"],
          outcome: "accepted",
          reason: "Accepted with limits"
        })
    end

    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.software}")
    assert has_element?(view, "#workstream-agreement-coverage", "may still be open")
    assert has_element?(view, "#workstream-doing", "shown")
    assert has_element?(view, "#workstream-todo", "shown")
    assert has_element?(view, "#workstream-blockers", "shown")
    refute has_element?(view, "#workstream-doing", "Older active assignment")
  end

  test "older agreement pages reach old open work by links, reload and refresh", ctx do
    owner = ctx.ids.software
    detail = "/workstreams/#{owner}"
    old = old_open_agreement!(owner)
    for n <- 1..6, do: accepted!(owner, "Accepted newer assignment #{n}")

    report!(
      owner,
      "Current report while paging agreements",
      %{},
      DateTime.add(DateTime.utc_now(), -60)
    )

    {:ok, ask} = Custode.Asks.ask(owner, "Which current release should I target?")
    agreement!(ctx.ids.research, "Earlier research agreement")
    for n <- 1..3, do: agreement!(ctx.ids.research, "Newest research agreement #{n}")
    before = counts()

    {:ok, view, _} = live(ctx.conn, detail)
    assert has_element?(view, "#workstream-agreement-coverage", "Limited agreement coverage")
    assert has_element?(view, "#workstream-agreement-coverage", "Reports, open questions")
    refute has_element?(view, "#workstream-agreement-coverage a", "Newest agreements")
    refute has_element?(view, "#workstream-doing", "old-assignment")
    assert_purposes(view, [6, 5, 4])

    second = click_older(view)
    assert second =~ ~r"^/workstreams/[^?]+\?agreements_before=[^&]+$"
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=older]")
    assert has_element?(view, "#workstream-agreement-coverage", "Still older agreements")
    assert has_element?(view, ~s(#workstream-agreement-coverage a[href="#{detail}"]), "Newest")
    assert_purposes(view, [3, 2, 1])

    third = click_older(view)
    assert_purposes(view, [])
    assert_old_page(view, old)
    assert has_element?(view, "#workstream-agreement-coverage", "Older agreements")
    assert has_element?(view, "#workstream-agreement-coverage", "No older agreements")
    refute has_element?(view, "#workstream-agreement-coverage a", "Older agreements")
    assert has_element?(view, "#workstream-done", "Current report while paging agreements")
    assert has_element?(view, "#workstream-decisions", "Which current release should I target?")

    {:ok, reloaded, _} = live(ctx.conn, third)
    assert_old_page(reloaded, old)
    assert counts() == before

    accepted!(owner, "Recorded after the page was opened")
    report!(owner, "Updated current report while paging agreements", %{})
    ask |> Ecto.Changeset.change(status: "answered", answer: "The next release") |> Repo.update!()
    before = counts()
    send(view.pid, {:work_agreement_changed, owner})
    send(view.pid, :refresh)
    assert_old_page(view, old)
    refute has_element?(view, "#workstream-purpose", "Recorded after the page was opened")

    assert has_element?(
             view,
             "#workstream-done",
             "Updated current report while paging agreements"
           )

    refute has_element?(view, "#workstream-done", "Current report while paging agreements")
    refute has_element?(view, "#workstream-decisions", "Which current release should I target?")

    {:ok, middle, _} = live(ctx.conn, second)
    assert_purposes(middle, [3, 2, 1])

    view |> element("#workstream-agreement-coverage a", "Newest agreements") |> render_click()
    assert_patch(view, detail)
    assert has_element?(view, "#workstream-purpose", "Recorded after the page was opened")
    refute has_element?(view, "#workstream-doing", "old-assignment")

    render_patch(view, third)
    assert_old_page(view, old)
    render_patch(view, "/workstreams/#{ctx.ids.research}")
    assert has_element?(view, "#workstream-detail[data-workstream-owner='#{ctx.ids.research}']")
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=newest]")
    assert has_element?(view, "#workstream-purpose", "Newest research agreement 3")
    refute has_element?(view, "#workstream-purpose", "Earlier research agreement")
    refute has_element?(view, "#workstream-doing", "old-assignment")
    render_patch(view, third)
    assert_old_page(view, old)
    view |> element("#workstream-detail a", "All workstreams") |> render_click()
    assert_patch(view, "/")
    assert has_element?(view, "#workstream-home")
    render_patch(view, detail)
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=newest]")
    refute has_element?(view, "#workstream-doing", "old-assignment")
    assert counts() == before
  end

  test "malformed, stale and foreign agreement cursors are errors with a newest recovery link",
       ctx do
    owner = ctx.ids.software
    detail = "/workstreams/#{owner}"
    agreement!(owner, "Current owner assignment")
    foreign = agreement!(ctx.ids.research, "Another owner's assignment")
    before = counts()

    for {cursor, message} <- [
          {"", "malformed"},
          {String.duplicate("x", 161), "malformed"},
          {foreign, "does not match a current agreement"},
          {Ecto.UUID.generate(), "does not match a current agreement"}
        ] do
      {:ok, view, _} = live(ctx.conn, "#{detail}?agreements_before=#{cursor}")
      assert has_element?(view, "#workstream-error [role=alert]", message)
      refute has_element?(view, "#workstream-detail")
      refute has_element?(view, "#workstream-purpose", "Another owner's assignment")

      send(view.pid, :refresh)
      assert has_element?(view, "#workstream-error [role=alert]", message)

      view
      |> element(~s(#workstream-error nav a[href="#{detail}"]), "Newest agreements")
      |> render_click()

      assert_patch(view, detail)
      assert has_element?(view, "#workstream-purpose", "Current owner assignment")
      refute has_element?(view, "#workstream-error")
    end

    {:ok, home, _} = live(ctx.conn, "/?agreements_before=#{foreign}")
    assert has_element?(home, "#workstream-error", "apply to one workstream")
    refute has_element?(home, "#workstream-error a", "Newest agreements")
    refute has_element?(home, "#workstream-home")
    assert counts() == before
  end

  test "failed reports do not become a completed-outcome count", ctx do
    at = DateTime.utc_now()

    Repo.insert!(%Feed.Entry{
      agent: ctx.ids.software,
      event: "turn_failed",
      at: at,
      entry:
        Jason.encode!(%{
          agent: ctx.ids.software,
          event: "turn_failed",
          summary: "Could not complete the checks"
        })
    })

    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.software}")
    assert has_element?(view, "#workstream-done > summary", "Done")
    refute has_element?(view, "#workstream-done > summary span")
    assert has_element?(view, "#workstream-done", "recorded failed turn")
  end

  test "question gates are not mislabeled as approval gates", ctx do
    Repo.insert!(%Custode.Gates.Gate{
      agent_id: ctx.ids.research,
      action_id: uid("question"),
      kind: "question",
      detail: "Which scope should I use?",
      status: "open"
    })

    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.research}")
    assert has_element?(view, "#workstream-decisions", "Open gate")
    assert has_element?(view, "#workstream-decisions", "Which scope should I use?")
    refute has_element?(view, "#workstream-decisions", "Open approval gate")
  end

  test "long untrusted text is escaped and folded behind keyboard disclosures", ctx do
    long =
      String.duplicate("Read the evidence before deciding. ", 30) <> "<script>alert(1)</script>"

    agreement!(ctx.ids.research, long)
    {:ok, view, html} = live(ctx.conn, "/workstreams/#{ctx.ids.research}")
    assert has_element?(view, "details[phx-hook=DisclosureState] > summary")
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
    assert has_element?(view, "#workstream-detail")
  end

  test "empty roster and unknown owner retain paths to setup and existing controls", ctx do
    put_env!(:routines, [])
    {:ok, empty, _} = live(ctx.conn, "/")
    assert has_element?(empty, "#workstream-home")
    assert has_element?(empty, ~s(a[href="/console"]))
    {:ok, missing, _} = live(ctx.conn, "/workstreams/does-not-exist")
    assert has_element?(missing, "#workstream-error")
    assert has_element?(missing, ~s(a[href="/"]))
  end

  defp agreement!(owner, outcome) do
    {:ok, receipt} =
      WorkAgreements.create(@human, %{
        request_id: uid("create"),
        routine_id: owner,
        intent: %{
          outcome: outcome,
          assignment_id: "bounded-assignment",
          criteria: [%{id: "evidence", text: "Record the outcome with sources and limits"}]
        }
      })

    receipt["agreement_id"]
  end

  defp old_open_agreement!(owner) do
    id = agreement!(owner, "Oldest open assignment")

    {:ok, _} =
      WorkAgreements.revise(@human, id, %{
        request_id: uid("revise"),
        expected_revision: 1,
        intent: %{
          outcome: "Oldest open assignment, revised",
          assignment_id: "old-assignment",
          criteria: [%{id: "evidence", text: "Record the outcome with sources and limits"}]
        }
      })

    checkpoint!(id, "Oldest committed step", "Oldest unresolved blocker", 2)
    id
  end

  defp accepted!(owner, outcome) do
    id = agreement!(owner, outcome)

    {:ok, submission} =
      WorkAgreements.submit(@human, id, %{
        request_id: uid("page-submit"),
        agreement_revision: 1,
        assignment_id: "bounded-assignment",
        summary: "Reviewed #{outcome}",
        criterion_evidence: [
          %{criterion_id: "evidence", references: [], note: "No further source available"}
        ],
        verification_limits: "No independent verification"
      })

    {:ok, _} =
      WorkAgreements.resolve(@human, id, %{
        request_id: uid("page-resolve"),
        expected_revision: 1,
        submission_id: submission["record_id"],
        outcome: "accepted",
        reason: "Accepted with limits"
      })

    id
  end

  defp click_older(view) do
    view
    |> element("#workstream-agreement-coverage nav[aria-label='Agreement pages'] a", "Older")
    |> render_click()

    assert_patch(view)
  end

  defp assert_purposes(view, shown) do
    for n <- 1..6 do
      selector = "#workstream-purpose"
      text = "Accepted newer assignment #{n}"

      if n in shown,
        do: assert(has_element?(view, selector, text)),
        else: refute(has_element?(view, selector, text))
    end
  end

  defp assert_old_page(view, old) do
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=older]")
    assert has_element?(view, "#workstream-purpose", "Oldest open assignment, revised")
    assert has_element?(view, "#workstream-doing", "old-assignment")
    assert has_element?(view, "#workstream-doing", old)
    assert has_element?(view, "#workstream-doing", "revision 2")
    assert has_element?(view, "#workstream-doing", "One bounded follow-up remains")
    assert has_element?(view, "#workstream-todo", "Oldest committed step")
    assert has_element?(view, "#workstream-todo", "revision 2")
    assert has_element?(view, "#workstream-blockers", "Oldest unresolved blocker")
    assert has_element?(view, "#workstream-blockers", "operator")
    assert has_element?(view, "#workstream-todo > summary", "1 shown")
  end

  defp checkpoint!(id, step, blocker, revision \\ 1) do
    {:ok, _} =
      WorkAgreements.checkpoint(@human, id, %{
        request_id: uid("checkpoint"),
        expected_revision: revision,
        summary: "One bounded follow-up remains",
        next_steps: [%{id: "next", text: step, references: []}],
        blockers: [
          %{
            id: "source",
            text: blocker,
            resolver: %{kind: "operator", id: @human.id},
            references: []
          }
        ]
      })
  end

  defp report!(owner, summary, report, at \\ DateTime.utc_now()) do
    Repo.insert!(%Feed.Entry{
      agent: owner,
      event: "turn",
      at: at,
      entry:
        Jason.encode!(%{
          agent: owner,
          event: "turn",
          at: DateTime.to_iso8601(at),
          summary: summary,
          report: report
        })
    })
  end

  defp counts do
    {Repo.aggregate(Oban.Job, :count), Repo.aggregate(Custode.OperatorMessage, :count),
     Repo.aggregate(Custode.PeerMessage, :count)}
  end
end
