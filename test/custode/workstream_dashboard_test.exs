defmodule Custode.WorkstreamDashboardTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Feed,
    NextBeat,
    ProjectReportDigest,
    Repo,
    Signal,
    WorkAgreements,
    WorkstreamDashboard
  }

  @operator %{kind: :operator, id: "workstream-dashboard-operator"}

  setup do
    clear_attention!()
    software = routine("software", :claude)
    research = routine("research", :codex)
    quiet = routine("quiet", :claude)
    manager = routine("manager", :claude) |> Map.put(:role, :caretaker)
    routines = [software, research, quiet, manager]
    ids = Enum.map(routines, & &1.id)
    put_env!(:routines, routines)

    on_exit(fn ->
      agreement_ids =
        Repo.all(
          from(a in WorkAgreements.Agreement,
            where: a.routine_id in ^ids,
            select: a.agreement_id
          )
        )

      Repo.delete_all(from(r in WorkAgreements.Record, where: r.agreement_id in ^agreement_ids))
      Repo.delete_all(from(a in WorkAgreements.Agreement, where: a.routine_id in ^ids))
      Repo.delete_all(from(f in Feed.Entry, where: f.agent in ^ids))
      Repo.delete_all(from(a in Custode.Asks.Ask, where: a.agent_id in ^ids))
      Repo.delete_all(from(g in Custode.Gates.Gate, where: g.agent_id in ^ids))
      Repo.delete_all(from(n in NextBeat, where: n.routine_id in ^ids))
      Repo.delete_all(from(s in Custode.AgentAuthorizationSnapshot, where: s.routine_id in ^ids))
    end)

    %{
      software: software,
      research: research,
      quiet: quiet,
      manager: manager,
      routines: routines,
      now: DateTime.utc_now()
    }
  end

  test "software and research retain acceptance, evidence limits and committed steps separately from reports",
       ctx do
    software = agreement!(ctx.software.id, "Ship the compatibility fix")
    research = agreement!(ctx.research.id, "Compare the supplied research sources")
    checkpoint!(ctx.software.id, software, "Run the compatibility checks")
    checkpoint!(ctx.research.id, research, "Compare the remaining source")

    submit_and_accept!(
      ctx.software.id,
      software,
      "The compatibility fix is ready",
      "commit:abc123"
    )

    submit_and_accept!(ctx.research.id, research, "Comparison complete", "research/findings.md")

    report!(ctx.software.id, ctx.now, %{
      "done" => ["Agent reports the fix is complete"],
      "verified" => ["Agent reports checks passed"],
      "next" => ["Suggested future migration"]
    })

    before = dispatch_counts()
    assert {:ok, dashboard} = WorkstreamDashboard.read(@operator, now: ctx.now)
    assert dispatch_counts() == before
    assert dashboard.schema_version == "custode.workstream_dashboard.v1"

    for {routine, expected, step} <- [
          {ctx.software, "Ship the compatibility fix", "Run the compatibility checks"},
          {ctx.research, "Compare the supplied research sources", "Compare the remaining source"}
        ] do
      stream = stream(dashboard, routine.id)

      assert [%{text: ^expected, revision: 1, recorded_by: %{"kind" => "operator"}}] =
               stream.purpose.entries

      assert stream.purpose.evidence == "attributed_bookkeeping"
      assert [agreement] = stream.agreements["agreements"]
      current = agreement["current"]
      assert current["status"] == "accepted"
      assert current["resolution"]["recorded_by"]["kind"] == "operator"

      assert current["resolution"]["payload"]["submission_id"] ==
               current["submission"]["record_id"]

      assert [%{"text" => ^step}] = current["checkpoint"]["payload"]["next_steps"]

      assert current["submission"]["payload"]["verification_limits"] ==
               "Only the supplied evidence was reviewed."

      assert [_reference] = current["submission"]["payload"]["criterion_evidence"]
      assert stream.execution.active == nil
      assert stream.execution.desired == nil
      assert stream.execution.turns == []
      assert stream.links.conversation == "/agents/#{routine.id}/conversation"
      refute Map.has_key?(stream, :conversation)
      assert :offline = Custode.Agents.live_provider(routine.id)

      assert {:ok, selected} = WorkstreamDashboard.read(@operator, routine_id: routine.id)

      assert stream(selected, routine.id).execution.desired.provider ==
               to_string(routine.provider)
    end

    assert dispatch_counts() == before
    assert [report] = stream(dashboard, ctx.software.id).digest.reports
    assert report.report["next"] == ["Suggested future migration"]
    assert report.evidence == "agent_authored"
  end

  test "detail loads full bounded ask question and context without changing the digest", ctx do
    question = String.duplicate("Question evidence. ", 80) <> "Question tail"
    context = String.duplicate("Context evidence. ", 80) <> "Context tail"
    ask = ask!(ctx.software.id, ctx.now, question)
    ask |> Ecto.Changeset.change(detail: context) |> Repo.update!()
    ask!(ctx.research.id, ctx.now, "Foreign question")

    for n <- 1..12 do
      ask!(ctx.software.id, DateTime.add(ctx.now, n), "Additional question #{n}")
    end

    before = dispatch_counts()
    assert {:ok, home} = WorkstreamDashboard.read(@operator)
    overview = stream(home, ctx.software.id)
    assert overview.decisions == overview.digest.decisions
    assert String.length(hd(overview.decisions.asks).text) == 1000
    refute Map.has_key?(hd(overview.decisions.asks), :context)

    assert {:ok, detail} = WorkstreamDashboard.read(@operator, routine_id: ctx.software.id)
    selected = stream(detail, ctx.software.id)
    assert selected.digest.decisions == overview.digest.decisions
    assert length(selected.decisions.asks) == length(overview.digest.decisions.asks)
    assert selected.decisions.has_more_asks

    assert %{id: id, text: ^question, context: ^context, owner: owner} =
             hd(selected.decisions.asks)

    assert id == ask.id
    assert owner == ctx.software.id
    assert Enum.all?(selected.decisions.asks, &(&1.owner == ctx.software.id))
    assert dispatch_counts() == before
  end

  test "requested next beats override cron while unscheduled manual routines remain explicit",
       ctx do
    scheduled = [ctx.software.id, ctx.research.id]

    routines =
      Enum.map(ctx.routines, fn routine ->
        if routine.id in scheduled, do: %{routine | cron: "* * * * *"}, else: routine
      end)

    put_env!(:routines, routines)
    assert {:ok, %{at: requested}} = NextBeat.request(ctx.software.id, 60)
    assert {:ok, dashboard} = WorkstreamDashboard.read(@operator)
    assert stream(dashboard, ctx.software.id).next_beat_at == requested
    assert %DateTime{} = cron_at = stream(dashboard, ctx.research.id).next_beat_at
    assert DateTime.compare(cron_at, requested) == :lt
    assert stream(dashboard, ctx.software.id).state.label == "Scheduled"
    assert stream(dashboard, ctx.quiet.id).next_beat_at == nil
  end

  test "missing agreements and stale reports do not invent purpose, execution or inactivity",
       ctx do
    old = DateTime.add(ctx.now, -72 * 3600)
    report!(ctx.research.id, old, %{"done" => ["A retained research finding"]})
    assert {:ok, dashboard} = WorkstreamDashboard.read(@operator, now: ctx.now)
    quiet = stream(dashboard, ctx.quiet.id)
    research = stream(dashboard, ctx.research.id)

    assert quiet.purpose.state == "missing"
    assert quiet.purpose.entries == []
    assert quiet.agreements["agreements"] == []
    assert quiet.digest.freshness.state == "missing"
    assert quiet.state.label == "Unknown"
    assert quiet.state.detail =~ "missing reports do not establish inactivity"
    assert quiet.execution.applied == nil
    assert quiet.next_beat_at == nil
    assert research.digest.freshness.state == "stale"
    assert research.digest.freshness.latest_recorded_at == DateTime.to_iso8601(old)
    assert [%{report: %{"done" => ["A retained research finding"]}}] = research.digest.reports
    assert research.purpose.state == "missing"

    assert {:ok, recent} = WorkstreamDashboard.read(@operator, now: ctx.now, window_hours: 24)
    assert stream(recent, ctx.research.id).digest.reports == []
    assert stream(recent, ctx.research.id).digest.freshness.state == "stale"
  end

  test "multiple agreements remain bounded and a revised intent cannot inherit acceptance", ctx do
    original = agreement!(ctx.software.id, "First purpose")
    submit_and_accept!(ctx.software.id, original, "First result", "first.md")

    assert {:ok, _} =
             WorkAgreements.revise(@operator, original["agreement_id"], %{
               "request_id" => uid("revision"),
               "expected_revision" => 1,
               "intent" => intent("Revised purpose")
             })

    agreement!(ctx.software.id, "Second purpose")
    agreement!(ctx.software.id, "Third purpose")

    assert {:ok, bounded} = WorkstreamDashboard.read(@operator, agreement_limit: 2)
    row = stream(bounded, ctx.software.id)
    assert length(row.purpose.entries) == 2
    assert row.purpose.has_more
    assert row.agreements["has_more"]
    assert row.agreements["before_id"]
    assert bounded.coverage.agreement_limit == 2

    assert {:ok, full} = WorkstreamDashboard.read(@operator)

    revised =
      Enum.find(
        stream(full, ctx.software.id).agreements["agreements"],
        &(&1["agreement_id"] == original["agreement_id"])
      )

    assert revised["current_revision"] == 2
    assert revised["current"]["status"] == "open"
    assert revised["current"]["submission"] == nil
    assert revised["current"]["resolution"] == nil
  end

  test "a detail read pages older agreements by cursor without hiding old open work", ctx do
    old = agreement!(ctx.software.id, "Oldest open assignment")

    assert {:ok, _} =
             WorkAgreements.revise(@operator, old["agreement_id"], %{
               "request_id" => uid("revision"),
               "expected_revision" => 1,
               "intent" => intent("Oldest open assignment, revised")
             })

    old_checkpoint = checkpoint!(ctx.software.id, old, "Finish the oldest step", 2)

    newer =
      for n <- 1..6 do
        agreement = agreement!(ctx.software.id, "Accepted newer assignment #{n}")
        submit_and_accept!(ctx.software.id, agreement, "Result #{n}", "result-#{n}.md")
        agreement
      end

    expected = Enum.reverse(Enum.map([old | newer], & &1["agreement_id"]))
    before = dispatch_counts()
    detail = "/workstreams/#{URI.encode(ctx.software.id, &URI.char_unreserved?/1)}"

    assert {:ok, newest} = WorkstreamDashboard.read(@operator, routine_id: ctx.software.id)
    first = stream(newest, ctx.software.id)
    assert newest.coverage.agreement_page == :newest
    assert newest.coverage.agreement_before == nil
    assert first.agreement_page.position == :newest
    assert first.agreement_page.newest == nil
    assert first.agreement_page.shown == 3
    assert first.agreement_page.has_more

    assert first.agreement_page.older ==
             detail <> "?agreements_before=" <> first.agreements["before_id"]

    refute Enum.any?(first.agreements["agreements"], &(&1["agreement_id"] == old["agreement_id"]))

    pages = pages(ctx.software.id, first.agreements["before_id"], [first])
    assert Enum.flat_map(pages, &agreement_ids/1) == expected
    assert length(pages) == 3

    last = List.last(pages)
    assert last.agreement_page.position == :older
    refute last.agreement_page.has_more
    assert last.agreement_page.older == nil
    assert last.agreement_page.newest == detail
    assert [oldest] = last.agreements["agreements"]
    assert oldest["agreement_id"] == old["agreement_id"]
    assert oldest["current_revision"] == 2
    assert oldest["current"]["status"] == "open"
    assert oldest["current"]["intent"]["outcome"] == "Oldest open assignment, revised"
    assert oldest["current"]["checkpoint"]["record_id"] == old_checkpoint["record_id"]
    assert oldest["current"]["checkpoint"]["revision"] == 2

    assert [%{"text" => "Finish the oldest step"}] =
             oldest["current"]["checkpoint"]["payload"]["next_steps"]

    assert [%{"id" => "source"}] = oldest["current"]["checkpoint"]["payload"]["blockers"]

    middle = Enum.at(pages, 1)
    assert dispatch_counts() == before
    agreement!(ctx.software.id, "Recorded after the page was opened")
    before = dispatch_counts()

    assert {:ok, reread} =
             WorkstreamDashboard.read(@operator,
               routine_id: ctx.software.id,
               agreement_before: middle.agreement_page.before
             )

    assert agreement_ids(stream(reread, ctx.software.id)) == agreement_ids(middle)

    assert reread.coverage.agreement_page == :older
    assert reread.coverage.agreement_before == middle.agreement_page.before
    assert dispatch_counts() == before
  end

  test "agreement cursors are detail-only and stale or foreign cursors are errors", ctx do
    own = agreement!(ctx.software.id, "Owner agreement")
    foreign = agreement!(ctx.research.id, "Foreign agreement")
    before = dispatch_counts()

    assert {:error, :invalid_options} =
             WorkstreamDashboard.read(@operator, agreement_before: own["agreement_id"])

    for cursor <- ["", "   ", String.duplicate("x", 161), 12, false] do
      assert {:error, :invalid_arguments} =
               WorkstreamDashboard.read(@operator,
                 routine_id: ctx.software.id,
                 agreement_before: cursor
               )
    end

    for cursor <- [foreign["agreement_id"], Ecto.UUID.generate()] do
      assert {:error, :invalid_cursor} =
               WorkstreamDashboard.read(@operator,
                 routine_id: ctx.software.id,
                 agreement_before: cursor
               )
    end

    assert {:error, _} =
             WorkstreamDashboard.read(@operator,
               routine_id: ctx.software.id,
               agreement_before: own["agreement_id"],
               agreement_limit: 0
             )

    assert {:ok, overview} = WorkstreamDashboard.read(@operator)
    assert overview.coverage.agreement_page == :newest
    assert stream(overview, ctx.software.id).agreement_page.older == nil
    assert dispatch_counts() == before
  end

  test "attention keeps the resolver's oldest-first order and independent open decisions", ctx do
    older = DateTime.add(DateTime.utc_now(), -7200)
    newer = DateTime.add(older, 3600)
    ask!(ctx.research.id, older, "Choose the research scope")
    ask!(ctx.software.id, newer, "Choose the software target")

    assert {:ok, dashboard} = WorkstreamDashboard.read(@operator)
    ids = Enum.map(dashboard.attention, & &1.subject)
    assert ids == [ctx.research.id, ctx.software.id]
    assert Enum.map(Enum.take(dashboard.workstreams, 2), & &1.id) == ids
    assert stream(dashboard, ctx.research.id).state.label == "Waiting"

    assert [%{blocking: false, text: "Choose the research scope"}] =
             stream(dashboard, ctx.research.id).digest.decisions.asks

    assert stream(dashboard, ctx.research.id).execution.active == nil
  end

  test "a scoped read reaches owners outside the overview limit through the shared digest", ctx do
    extras = for n <- 1..51, do: %{ctx.quiet | id: uid("bounded-#{n}")}
    target = %{ctx.software | id: "zz-#{uid("target")}"}
    put_env!(:routines, extras ++ [target])
    assert {:ok, overview} = WorkstreamDashboard.read(@operator, now: ctx.now)
    assert overview.coverage.configured_projects == 52
    assert overview.coverage.shown_projects == 50
    assert overview.coverage.has_more_projects
    refute Enum.any?(overview.workstreams, &(&1.id == target.id))

    assert {:ok, selected} =
             WorkstreamDashboard.read(@operator, routine_id: target.id, now: ctx.now)

    assert [%{id: id, digest: actual}] = selected.workstreams
    assert id == target.id
    assert selected.coverage.shown_projects == 1

    assert {:ok, expected} =
             ProjectReportDigest.read_project(@operator, target.id,
               now: ctx.now,
               window_hours: 168
             )

    assert actual == expected

    assert {:error, :unknown_routine} =
             WorkstreamDashboard.read(@operator, routine_id: uid("unknown"))

    assert {:error, :invalid_routine_id} = ProjectReportDigest.read_project(@operator, "")
  end

  test "operator and caretaker can read without granting worker or helper access", ctx do
    assert {:ok, _} = WorkstreamDashboard.read(%{kind: :routine, id: ctx.manager.id})

    for actor <- [
          nil,
          %{},
          %{kind: :operator, id: ""},
          %{kind: :routine, id: ctx.software.id},
          %{kind: :sub_agent, id: "helper"}
        ] do
      assert {:error, _} = WorkstreamDashboard.read(actor)
      assert {:error, _} = ProjectReportDigest.read_project(actor, ctx.software.id)
    end

    for opts <- [
          [agreement_limit: 0],
          [agreement_limit: 11],
          [project_limit: 51],
          [window_hours: 169],
          [report_limit: 4],
          [routine_id: 12],
          [unknown: true],
          [agreement_limit: 1, agreement_limit: 2],
          %{}
        ] do
      assert {:error, _} = WorkstreamDashboard.read(@operator, opts)
    end
  end

  test "lifecycle labels preserve paused settlement, missing observations and scheduled quiet work" do
    absent = %{applied: nil, active: nil, live_error: nil}
    paused = %{absent | applied: %{state: "paused"}, active: %{state: "executing"}}

    assert %{label: "Paused", detail: detail} =
             WorkstreamDashboard.execution_state(paused, nil, nil)

    assert detail =~ "does not confirm the provider process stopped"
    assert %{label: "Unknown"} = WorkstreamDashboard.execution_state(absent, nil, nil)

    assert %{label: "Unknown"} =
             WorkstreamDashboard.execution_state(%{absent | live_error: "unavailable"}, nil, nil)

    assert %{label: "Quiet"} =
             WorkstreamDashboard.execution_state(%{absent | applied: %{state: "idle"}}, nil, nil)

    assert %{label: "Scheduled"} =
             WorkstreamDashboard.execution_state(absent, nil, DateTime.utc_now())

    assert %{label: "Working"} =
             WorkstreamDashboard.execution_state(
               %{absent | applied: %{state: "running"}},
               nil,
               nil
             )

    signal = %Signal{
      subject: "owner",
      kind: :red_main,
      group: :needs_you,
      urgency: :high,
      headline: "main is red"
    }

    assert %{label: "Blocked"} = WorkstreamDashboard.execution_state(absent, signal, nil)
  end

  defp routine(name, provider) do
    %{
      id: uid("dashboard-#{name}"),
      role: :assistant,
      provider: provider,
      cron: :manual,
      workspace: tmp_workspace!(),
      prompt: "Unrecorded standing prompt must not become a work agreement",
      on_note: :ignore
    }
  end

  defp stream(dashboard, id), do: Enum.find(dashboard.workstreams, &(&1.id == id))

  defp agreement_ids(stream), do: Enum.map(stream.agreements["agreements"], & &1["agreement_id"])

  defp pages(_owner, nil, acc), do: Enum.reverse(acc)

  defp pages(owner, cursor, acc) do
    assert length(acc) < 10, "agreement pages did not terminate"

    assert {:ok, dashboard} =
             WorkstreamDashboard.read(@operator, routine_id: owner, agreement_before: cursor)

    page = stream(dashboard, owner)
    assert page.agreement_page.before == cursor
    pages(owner, page.agreements["before_id"], [page | acc])
  end

  defp intent(outcome) do
    %{
      "outcome" => outcome,
      "assignment_id" => uid("assignment"),
      "criteria" => [%{"id" => "evidence", "text" => "Record the evidence and its limits"}]
    }
  end

  defp agreement!(owner, purpose) do
    attrs = %{
      "request_id" => uid("agreement"),
      "routine_id" => owner,
      "intent" => intent(purpose)
    }

    assert {:ok, receipt} = WorkAgreements.create(@operator, attrs)
    Map.put(receipt, "intent", attrs["intent"])
  end

  defp checkpoint!(owner, agreement, step, revision \\ 1) do
    assert {:ok, receipt} =
             WorkAgreements.checkpoint(%{kind: :routine, id: owner}, agreement["agreement_id"], %{
               "request_id" => uid("checkpoint"),
               "expected_revision" => revision,
               "summary" => "Recorded checkpoint",
               "next_steps" => [%{"id" => "next", "text" => step}],
               "blockers" => [
                 %{
                   "id" => "source",
                   "text" => "A missing source prevents the comparison",
                   "resolver" => %{"kind" => "operator", "id" => @operator.id}
                 }
               ],
               "decisions" => []
             })

    receipt
  end

  defp submit_and_accept!(owner, agreement, summary, output) do
    assert {:ok, submission} =
             WorkAgreements.submit(%{kind: :routine, id: owner}, agreement["agreement_id"], %{
               "request_id" => uid("submission"),
               "agreement_revision" => 1,
               "assignment_id" => agreement["intent"]["assignment_id"],
               "summary" => summary,
               "criterion_evidence" => [
                 %{
                   "criterion_id" => "evidence",
                   "references" => [%{"kind" => "other", "value" => output}],
                   "note" => "Recorded result"
                 }
               ],
               "verification_limits" => "Only the supplied evidence was reviewed."
             })

    assert {:ok, _} =
             WorkAgreements.resolve(@operator, agreement["agreement_id"], %{
               "request_id" => uid("resolution"),
               "expected_revision" => 1,
               "submission_id" => submission["record_id"],
               "outcome" => "accepted",
               "reason" => "This exact result satisfies the recorded purpose"
             })
  end

  defp report!(owner, at, report) do
    entry = %{
      agent: owner,
      event: "turn",
      at: DateTime.to_iso8601(at),
      summary: "Recorded owner update",
      report: report
    }

    Repo.insert!(%Feed.Entry{agent: owner, event: "turn", at: at, entry: Jason.encode!(entry)})
  end

  defp ask!(owner, at, question) do
    Repo.insert!(%Custode.Asks.Ask{
      agent_id: owner,
      question: question,
      status: "open",
      inserted_at: at
    })
  end

  defp dispatch_counts do
    %{
      jobs: Repo.aggregate(Oban.Job, :count),
      operator_messages: Repo.aggregate(Custode.OperatorMessage, :count),
      peer_messages: Repo.aggregate(Custode.PeerMessage, :count)
    }
  end
end
