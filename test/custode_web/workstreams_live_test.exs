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

    %{ids: ids, workspace: workspace, conn: build_conn()}
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

  test "answers the exact displayed question once and updates another open view", ctx do
    owner = ctx.ids.software
    first = ask!(owner, "First choice")
    second = ask!(owner, "Second choice")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{owner}")
    {:ok, other, _} = live(ctx.conn, "/workstreams/#{owner}")
    {:ok, home, _} = live(ctx.conn, "/")
    assert has_element?(home, "#workstream-attention", owner)
    before = counts()
    view |> answer_form(second, "Keep this other draft") |> render_change()
    other |> answer_form(second, "Draft in another open view") |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-answer-text-#{second.id}", "Keep this other draft")

    assert has_element?(
             view,
             "#workstream-answer-#{first.id} label[for=workstream-answer-text-#{first.id}]"
           )

    assert has_element?(view, "#workstream-answer-text-#{first.id}[required]")
    assert has_element?(view, "#workstream-answer-#{first.id} button[type=submit]", "Send answer")

    view |> answer_form(first, "  Choose first  ") |> render_submit()
    assert Custode.Asks.get(first.id).answer == "Choose first"
    assert Custode.Asks.get(first.id).status == "answered"
    assert Custode.Asks.get(second.id).status == "open"
    assert has_element?(view, "#workstream-answer-feedback[role=status]", "Answer sent")
    refute has_element?(view, "#workstream-answer-#{first.id}")
    assert has_element?(view, "#workstream-answer-#{second.id}")
    assert has_element?(view, "#workstream-answer-text-#{second.id}", "Keep this other draft")
    refute Map.has_key?(cached_answers(view), {owner, to_string(first.id)})

    eventually(fn ->
      refute has_element?(other, "#workstream-answer-#{first.id}")
      assert has_element?(other, "#workstream-answer-#{second.id}")

      assert has_element?(
               other,
               "#workstream-answer-text-#{second.id}",
               "Draft in another open view"
             )
    end)

    render_submit(view, "answer_ask", answer_params(first, "Duplicate"))

    assert has_element?(
             view,
             "#workstream-answer-feedback",
             "not displayed for this owner"
           )

    assert Custode.Asks.get(second.id).status == "open"
    assert answer_events(owner, first.id) == 1
    assert inbox_events(owner, first.id) == 1
    assert [path] = Path.wildcard(Path.join(ctx.workspace, "inbox/answer-#{first.id}.md"))
    assert File.read!(path) =~ "Choose first"
    view |> answer_form(second, "Finish the other question") |> render_submit()
    eventually(fn -> refute has_element?(home, "#workstream-attention", owner) end)
    assert cached_answers(view) == %{}
    assert counts() == before
  end

  test "refresh during typing keeps exact binding and the selected agreement page", ctx do
    owner = ctx.ids.software
    old_open_agreement!(owner)
    for n <- 1..6, do: accepted!(owner, "Accepted newer assignment #{n}")
    first = ask!(owner, "Original question")
    second = ask!(owner, "Other question")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{owner}")
    selected_page = click_older(view)
    view |> answer_form(first, "My unfinished answer") |> render_change()
    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-answer-text-#{first.id}", "My unfinished answer")

    render_patch(view, "/workstreams/#{owner}?agreements_before=missing-agreement")
    assert has_element?(view, "#workstream-error")
    render_patch(view, selected_page)
    assert has_element?(view, "#workstream-answer-text-#{first.id}", "My unfinished answer")

    assert {:ok, _} = Custode.Asks.dismiss(first.id)
    third = ask!(owner, "New question after typing")
    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-answer-text-#{first.id}", "My unfinished answer")
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=older]")
    assert_purposes(view, [1, 2, 3])

    view |> answer_form(first, "My unfinished answer") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{first.id}", "already dismissed")
    assert has_element?(view, "#workstream-answer-text-#{first.id}", "My unfinished answer")
    assert Custode.Asks.get(second.id).status == "open"
    assert Custode.Asks.get(third.id).status == "open"
    assert answer_events(owner, first.id) == 0
    assert inbox_events(owner, first.id) == 0
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=older]")
    # Reloading the same URL confirms the action did not replace its cursor.
    render_patch(view, selected_page)
    assert_purposes(view, [1, 2, 3])
    view |> answer_form(second, "Answer the other exact question") |> render_submit()
    assert Custode.Asks.get(second.id).status == "answered"
    assert Custode.Asks.get(third.id).status == "open"
    assert has_element?(view, "#workstream-agreement-coverage[data-agreement-page=older]")
    assert_purposes(view, [1, 2, 3])
  end

  test "blank and stale answers keep drafts and never dispatch another question", ctx do
    owner = ctx.ids.research
    blank = ask!(owner, "Needs an answer")
    closed = ask!(owner, "Answered elsewhere")
    gone = ask!(owner, "Deleted elsewhere")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{owner}")
    before = counts()

    view |> answer_form(blank, "   ") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{blank.id}[role=alert]", "needs text")
    assert has_element?(view, "#workstream-answer-text-#{blank.id}[aria-invalid=true]")

    assert render(view) =~
             ~r/<textarea[^>]+id="workstream-answer-text-#{blank.id}"[^>]*>\s*<\/textarea>/

    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-answer-error-#{blank.id}", "needs text")

    view |> answer_form(closed, "Retained stale answer") |> render_change()
    view |> answer_form(gone, "Retained missing answer") |> render_change()
    assert {:ok, _} = Custode.Asks.answer(closed.id, "External answer")
    Repo.delete!(gone)
    render_submit(view, "answer_ask", answer_params(closed, "Retained stale answer"))
    assert has_element?(view, "#workstream-answer-error-#{closed.id}", "already answered")
    assert has_element?(view, "#workstream-answer-text-#{closed.id}", "Retained stale answer")
    render_submit(view, "answer_ask", answer_params(gone, "Retained missing answer"))
    assert has_element?(view, "#workstream-answer-error-#{gone.id}", "no ask")
    assert has_element?(view, "#workstream-answer-text-#{gone.id}", "Retained missing answer")
    assert Custode.Asks.get(blank.id).status == "open"
    assert answer_events(owner, blank.id) == 0
    assert answer_events(owner, closed.id) == 1
    assert inbox_events(owner, closed.id) == 1
    assert counts() == before
  end

  test "refresh prunes obsolete empty forms but preserves real drafts across owner navigation",
       ctx do
    owner = ctx.ids.software
    empty = ask!(owner, "Empty form", "Obsolete context")
    whitespace = ask!(owner, "Whitespace form")
    draft = ask!(owner, "Keep this draft")
    foreign = ask!(ctx.ids.research, "Another owner question")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{owner}")
    view |> answer_form(whitespace, "   ") |> render_change()
    view |> answer_form(draft, "Real unfinished answer") |> render_change()
    before = counts()
    assert {:ok, _} = Custode.Asks.dismiss(empty.id)
    assert {:ok, _} = Custode.Asks.dismiss(whitespace.id)
    assert {:ok, _} = Custode.Asks.dismiss(draft.id)
    send(view.pid, :refresh)
    refute has_element?(view, "#workstream-answer-#{empty.id}")
    refute has_element?(view, "#workstream-answer-#{whitespace.id}")
    assert has_element?(view, "#workstream-answer-text-#{draft.id}", "Real unfinished answer")
    assert Map.keys(cached_answers(view)) == [{owner, to_string(draft.id)}]

    fresh = ask!(owner, "Open but untouched form")
    send(view.pid, :refresh)
    assert has_element?(view, "#workstream-answer-#{fresh.id}")
    render_patch(view, "/workstreams/#{ctx.ids.research}")
    refute Map.has_key?(cached_answers(view), {owner, to_string(fresh.id)})
    view |> answer_form(foreign, "Keep another owner's draft") |> render_change()
    render_patch(view, "/")
    assert map_size(cached_answers(view)) == 2
    render_patch(view, "/workstreams/#{owner}")
    assert has_element?(view, "#workstream-answer-text-#{draft.id}", "Real unfinished answer")
    render_patch(view, "/workstreams/#{ctx.ids.research}")

    assert has_element?(
             view,
             "#workstream-answer-text-#{foreign.id}",
             "Keep another owner's draft"
           )

    assert Custode.Asks.get(foreign.id).status == "open"
    assert counts() == before
  end

  test "discarding a stale failed draft is local and editing clears obsolete errors", ctx do
    owner = ctx.ids.software
    stale = ask!(owner, "Stale question")
    other = ask!(owner, "Keep another draft")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{owner}")
    view |> answer_form(stale, "Stale draft") |> render_change()
    view |> answer_form(other, "Other unfinished answer") |> render_change()
    assert {:ok, _} = Custode.Asks.dismiss(stale.id)
    view |> answer_form(stale, "Stale draft") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{stale.id}", "already dismissed")

    view |> answer_form(stale, "Edited stale draft") |> render_change()
    refute has_element?(view, "#workstream-answer-error-#{stale.id}")
    assert has_element?(view, "#workstream-answer-text-#{stale.id}[aria-invalid=false]")
    view |> answer_form(stale, "Edited stale draft") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{stale.id}", "already dismissed")
    before = counts()
    closed = Custode.Asks.get(stale.id)
    open = Custode.Asks.get(other.id)
    events = Repo.aggregate(Feed.Entry, :count)

    render_click(view, "discard_answer", %{answer_params(stale, "") | "owner" => ctx.ids.research})

    assert has_element?(view, "#workstream-answer-text-#{stale.id}", "Edited stale draft")

    view
    |> element("#workstream-answer-#{stale.id} button[type=button]", "Discard draft")
    |> render_click()

    refute has_element?(view, "#workstream-answer-#{stale.id}")
    refute Map.has_key?(cached_answers(view), {owner, to_string(stale.id)})
    assert has_element?(view, "#workstream-answer-text-#{other.id}", "Other unfinished answer")
    assert has_element?(view, "#workstream-answer-feedback[role=status]", "Draft discarded")
    assert Custode.Asks.get(stale.id) == closed
    assert Custode.Asks.get(other.id) == open
    assert Repo.aggregate(Feed.Entry, :count) == events
    assert answer_events(owner, stale.id) == 0
    assert inbox_events(owner, stale.id) == 0
    assert counts() == before

    # Editing an open question clears its obsolete validation error.
    render_patch(view, "/workstreams/#{ctx.ids.research}")
    render_patch(view, "/workstreams/#{owner}")
    assert has_element?(view, "#workstream-answer-text-#{other.id}", "Other unfinished answer")
    view |> answer_form(other, " ") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{other.id}", "needs text")
    view |> answer_form(other, "Corrected answer draft") |> render_change()
    refute has_element?(view, "#workstream-answer-error-#{other.id}")
    assert Custode.Asks.get(other.id).status == "open"
    assert counts() == before

    # Clearing a failed stale draft also drops its error and cached context.
    assert {:ok, _} = Custode.Asks.dismiss(other.id)
    view |> answer_form(other, "Corrected answer draft") |> render_submit()
    assert has_element?(view, "#workstream-answer-error-#{other.id}", "already dismissed")
    view |> answer_form(other, "   ") |> render_change()
    refute has_element?(view, "#workstream-answer-#{other.id}")
    assert cached_answers(view) == %{}
    assert Custode.Asks.get(other.id).status == "dismissed"
    assert answer_events(owner, other.id) == 0
    assert inbox_events(owner, other.id) == 0
    assert counts() == before
  end

  test "foreign owners and undisplayed IDs cannot answer through a selected workstream", ctx do
    own = ask!(ctx.ids.software, "Own question")
    foreign = ask!(ctx.ids.research, "Foreign question")
    {:ok, view, _} = live(ctx.conn, "/workstreams/#{ctx.ids.software}")
    before = counts()

    for params <- [
          answer_params(foreign, "Foreign submission"),
          %{answer_params(foreign, "Forged owner") | "owner" => ctx.ids.software},
          %{answer_params(own, "Forged owner") | "owner" => ctx.ids.research}
        ] do
      render_submit(view, "answer_ask", params)
      assert has_element?(view, "#workstream-answer-feedback", "not displayed for this owner")
    end

    # Even a formerly displayed owner's form is rejected after owner selection changes.
    render_patch(view, "/workstreams/#{ctx.ids.research}")
    render_submit(view, "answer_ask", answer_params(own, "Old owner form"))
    assert Custode.Asks.get(own.id).status == "open"
    assert Custode.Asks.get(foreign.id).status == "open"
    assert answer_events(ctx.ids.software, own.id) == 0
    assert inbox_events(ctx.ids.research, foreign.id) == 0
    assert counts() == before
  end

  test "full question and context use keyboard disclosures and blocking records keep Console links",
       ctx do
    owner = ctx.ids.research

    question =
      String.duplicate("Read this evidence. ", 80) <> "Question tail <script>bad()</script>"

    context = String.duplicate("Source context. ", 100) <> "Context tail"
    ask = ask!(owner, question, context)

    for {kind, detail} <- [{"question", "Blocking choice"}, {"approval", "Approval choice"}] do
      Repo.insert!(%Custode.Gates.Gate{
        agent_id: owner,
        action_id: uid("blocking"),
        kind: kind,
        detail: detail,
        status: "open"
      })
    end

    before = counts()
    {:ok, view, html} = live(ctx.conn, "/workstreams/#{owner}")
    assert has_element?(view, "#decision-ask-#{ask.id} [data-foldable-full]", "Question tail")
    assert has_element?(view, "#decision-context-#{ask.id} [data-foldable-full]", "Context tail")

    assert has_element?(
             view,
             "#decision-ask-#{ask.id}-disclosure[phx-hook=DisclosureState] > summary"
           )

    assert has_element?(view, "#decision-context-#{ask.id}-disclosure > summary")
    refute html =~ "<script>bad()</script>"
    assert has_element?(view, "#workstream-decisions", "Blocking choice")
    assert has_element?(view, "#workstream-decisions", "Approval choice")

    assert has_element?(
             view,
             "#workstream-decisions a[href='/console/#{owner}']",
             "Open in Console"
           )

    assert length(Regex.scan(~r/<form[^>]+phx-submit="answer_ask"/, html)) == 1
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

  defp cached_answers(view), do: :sys.get_state(view.pid).socket.assigns.answer_forms

  defp ask!(owner, question, context \\ nil) do
    Repo.insert!(%Custode.Asks.Ask{agent_id: owner, question: question, detail: context})
  end

  defp answer_params(ask, text),
    do: %{"owner" => ask.agent_id, "ask_id" => to_string(ask.id), "text" => text}

  defp answer_form(view, ask, text),
    do: form(view, "#workstream-answer-#{ask.id}", answer_params(ask, text))

  defp answer_events(owner, ask_id) do
    Repo.all(from(f in Feed.Entry, where: f.agent == ^owner and f.event == "answered"))
    |> Enum.count(&(Jason.decode!(&1.entry)["ask_id"] == ask_id))
  end

  defp inbox_events(owner, ask_id) do
    Repo.all(from(f in Feed.Entry, where: f.agent == ^owner and f.event == "inbox_note"))
    |> Enum.count(&(Jason.decode!(&1.entry)["note"] == "answer-#{ask_id}.md"))
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
