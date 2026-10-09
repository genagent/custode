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

  defp checkpoint!(owner, agreement, step) do
    assert {:ok, _} =
             WorkAgreements.checkpoint(%{kind: :routine, id: owner}, agreement["agreement_id"], %{
               "request_id" => uid("checkpoint"),
               "expected_revision" => 1,
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
