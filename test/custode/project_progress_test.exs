defmodule Custode.ProjectProgressTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentAuthorizationSnapshot, Agents, ConversationArcs, InboxWake}
  alias Custode.Gates.Gate
  alias Custode.{OperatorMessage, OperatorMessages, PeerMessage, ProjectProgress, Repo, Routine}
  alias Custode.SpendLedger.Entry

  @operator %{kind: :operator, id: "project-progress-operator"}

  setup do
    caretaker = fixture(:caretaker, :claude)
    claude = fixture(:backlog_worker, :claude)
    codex = fixture(:backlog_worker, :codex)
    routines = [caretaker, claude, codex]
    ids = Enum.map(routines, & &1.id)
    put_env!(:routines, routines)

    on_exit(fn ->
      Repo.query!(
        "DELETE FROM work_agreement_records WHERE agreement_id IN " <>
          "(SELECT agreement_id FROM work_agreements WHERE routine_id IN (?, ?, ?))",
        ids
      )

      Repo.query!("DELETE FROM work_agreements WHERE routine_id IN (?, ?, ?)", ids)
      Repo.delete_all(from(m in OperatorMessage, where: m.target_agent_id in ^ids))
      Repo.delete_all(from(m in PeerMessage, where: m.recipient in ^ids))
      Repo.delete_all(from(w in InboxWake, where: w.routine_id in ^ids))
      Repo.delete_all(from(g in Gate, where: g.agent_id in ^ids))
      Repo.delete_all(from(e in Entry, where: e.agent_id in ^ids))
      Repo.delete_all(from(s in AgentAuthorizationSnapshot, where: s.routine_id in ^ids))

      Repo.delete_all(
        from(j in Oban.Job, where: fragment("json_extract(?, '$.agent_id')", j.meta) in ^ids)
      )
    end)

    %{caretaker: caretaker, claude: claude, codex: codex, actor: identity(caretaker.id)}
  end

  test "latest read includes complete queued constraints and results, excluding other evidence",
       ctx do
    older = for n <- 1..5, do: message!(ctx.claude.id, "prior instruction #{n}")
    output = String.duplicate("full result detail\n", 200) <> "Final evidence: commit abc123."
    completed = message!(ctx.claude.id, "Report the compatibility evidence.")

    completed =
      update!(completed,
        status: "completed",
        result: %{"output" => output, "usage" => %{"turns" => 1}}
      )

    constraint =
      String.duplicate("Preserve backward compatibility.\n", 300) <>
        "Newest constraint: do not publish."

    newest = message!(ctx.claude.id, constraint)
    _other_project = message!(ctx.codex.id, "private unrelated project prompt")

    _delegated =
      message!(ctx.claude.id, "private delegated-child prompt", identity(ctx.caretaker.id))

    peer = peer!(ctx.codex.id, ctx.claude.id, "private sibling peer body")

    for actor <- [ctx.actor, @operator] do
      assert {:ok, progress} = ProjectProgress.read(actor, ctx.claude.id)
      assert progress.schema_version == "custode.project_progress.v1"
      assert {:ok, _, 0} = DateTime.from_iso8601(progress.observed_at)
      assert progress.project.routine_id == ctx.claude.id
      assert progress.links.conversation == "/agents/#{ctx.claude.id}/conversation"
      assert progress.conversation.page == "latest"
      assert progress.conversation.snapshot_id == newest.id
      assert progress.conversation.has_older
      assert length(progress.conversation.exchanges) == 5

      assert Enum.map(progress.conversation.exchanges, & &1.id) ==
               Enum.map(Enum.take(older, -3) ++ [completed, newest], & &1.provider_correlation_id)

      [answer, queued] = Enum.take(progress.conversation.exchanges, -2)
      assert answer.answer == output
      assert answer.result == completed.result
      assert queued.status == "queued"
      assert queued.delivery == "queued"
      assert [%{id: id, text: ^constraint}] = queued.prompts
      assert id == newest.message_id

      encoded = Jason.encode!(progress)
      refute encoded =~ "private unrelated project prompt"
      refute encoded =~ "private delegated-child prompt"
      refute encoded =~ peer.body
      refute encoded =~ newest.idempotency_key
      refute Map.has_key?(progress, :peer_messages)
    end

    assert Repo.get!(PeerMessage, peer.id) == peer
    assert OperatorMessages.get(newest.message_id) == newest
    assert :offline = Agents.live_provider(ctx.claude.id)
  end

  test "caretaker reads owner reports without acquiring helper or sibling authority", ctx do
    Custode.Feed.record(%{
      event: "turn",
      agent: ctx.claude.id,
      summary: "Owner update.",
      report: %{"done" => ["Evaluated helper findings."]}
    })

    Custode.Feed.record(%{event: "turn", agent: ctx.codex.id, summary: "Other project."})
    assert {:ok, progress} = ProjectProgress.read(ctx.actor, ctx.claude.id)
    assert [%{"agent" => agent, "summary" => "Owner update."}] = progress.reports.entries
    assert agent == ctx.claude.id
    assert progress.reports.evidence == "agent_authored"
    assert {:error, _} = ProjectProgress.read(identity(ctx.codex.id), ctx.claude.id)
  end

  test "older pages retain their cutoff while a fresh read sees the newest continuation", ctx do
    oldest = message!(ctx.claude.id, "original question")
    middle = message!(ctx.claude.id, "middle exchange")
    newest = message!(ctx.claude.id, "newest exchange")
    oldest = update!(oldest, status: "waiting_for_input", detail: "Which environment?")

    assert {:ok, initial} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 1)
    assert initial.conversation.snapshot_id == newest.id
    assert [first] = initial.conversation.exchanges
    assert first.id == newest.provider_correlation_id

    continuation = message!(ctx.claude.id, "Newest constraint: staging only.")
    assert continuation.provider_correlation_id == oldest.provider_correlation_id
    middle = update!(middle, status: "completed", result: %{"output" => "middle result arrived"})

    assert {:ok, previous} =
             ProjectProgress.read(ctx.actor, ctx.claude.id,
               limit: 1,
               before: initial.conversation.before
             )

    assert previous.conversation.page == "older"
    assert previous.conversation.snapshot_id == initial.conversation.snapshot_id
    assert [middle_exchange] = previous.conversation.exchanges
    assert middle_exchange.id == middle.provider_correlation_id
    assert middle_exchange.answer == "middle result arrived"

    assert {:ok, last} =
             ProjectProgress.read(ctx.actor, ctx.claude.id,
               limit: 1,
               before: previous.conversation.before
             )

    assert [%{prompts: [%{text: "original question"}]}] = last.conversation.exchanges
    assert last.conversation.snapshot_id == initial.conversation.snapshot_id
    refute last.conversation.has_older
    assert last.conversation.before == nil

    assert {:ok, fresh} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 1)
    assert fresh.conversation.page == "latest"
    assert fresh.conversation.snapshot_id == continuation.id
    assert [exchange] = fresh.conversation.exchanges
    assert Enum.map(exchange.prompts, & &1.text) == [oldest.prompt, continuation.prompt]
  end

  test "rejects unrelated identities before disclosing configured project existence", ctx do
    for actor <- [
          identity(ctx.claude.id),
          identity(uid("unknown")),
          %{kind: :sub_agent, id: ctx.caretaker.id},
          %{},
          nil,
          %{kind: :routine, id: nil},
          %{kind: :routine, id: ""}
        ] do
      assert {:error, error} = ProjectProgress.read(actor, ctx.claude.id)
      assert is_binary(error)
      assert {:error, ^error} = ProjectProgress.read(actor, uid("missing"))
    end
  end

  for {old_role, next_role, allowed} <- [
        {:backlog_worker, :caretaker, false},
        {:caretaker, :backlog_worker, true}
      ] do
    @old_role old_role
    @next_role next_role
    @allowed allowed

    test "captured #{@old_role} authority survives a configured #{@next_role} role change", ctx do
      target = if @old_role == :caretaker, do: ctx.caretaker, else: ctx.claude
      old = Routine.get(target.id)
      revision = Routine.execution_revision(old)
      assert :ok = AgentAuthorizationSnapshot.put(old, revision)
      job = provider_job!(old, "suspended", revision)
      change_role!(old.id, @next_role)
      actor = identity(old.id)

      result = ProjectProgress.read(actor, ctx.codex.id)
      assert match?({:ok, _}, result) == @allowed

      update!(job, state: "completed")
      result = ProjectProgress.read(actor, ctx.codex.id)
      assert match?({:ok, _}, result) != @allowed
    end
  end

  test "validates bounds and scoped cursors without accepting read-source overrides", ctx do
    assert {:error, :invalid_routine_id} = ProjectProgress.read(@operator, nil)
    assert {:error, :invalid_routine_id} = ProjectProgress.read(@operator, "")
    assert {:error, :unknown_routine} = ProjectProgress.read(@operator, uid("missing"))

    for opts <- [%{}, [:limit], [limit: 1, limit: 2], [process: nil], [actor: @operator]] do
      assert {:error, :invalid_options} = ProjectProgress.read(ctx.actor, ctx.claude.id, opts)
    end

    for value <- [0, 21, "1", nil] do
      assert {:error, {:invalid_limit, ^value}} =
               ProjectProgress.read(ctx.actor, ctx.claude.id, limit: value)
    end

    assert {:error, {:invalid_before, 123}} =
             ProjectProgress.read(ctx.actor, ctx.claude.id, before: 123)

    assert {:error, {:invalid_cursor, ""}} =
             ProjectProgress.read(ctx.actor, ctx.claude.id, before: "")

    assert {:ok, empty} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 20)
    assert empty.conversation.snapshot_id == 0
    assert empty.conversation.exchanges == []

    message!(ctx.claude.id, "old")
    message!(ctx.claude.id, "new")
    {:ok, page} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 1)
    cursor = page.conversation.before

    assert {:error, {:invalid_cursor, ^cursor}} =
             ProjectProgress.read(ctx.actor, ctx.codex.id, before: cursor)
  end

  test "shares bounded agreement facts without calling a submitted result verified", ctx do
    intent = %{
      "outcome" => "Find the supported migration path",
      "assignment_id" => uid("progress-assignment"),
      "criteria" => [%{"id" => "compatibility", "text" => "Record compatibility evidence"}]
    }

    assert {:ok, created} =
             Custode.WorkAgreements.create(@operator, %{
               "request_id" => uid("progress-agreement"),
               "routine_id" => ctx.claude.id,
               "intent" => intent
             })

    agreement_id = created["agreement_id"]

    assert {:ok, _} =
             Custode.WorkAgreements.submit(identity(ctx.claude.id), agreement_id, %{
               "request_id" => uid("progress-submission"),
               "agreement_revision" => 1,
               "assignment_id" => intent["assignment_id"],
               "summary" => "The documented path appears compatible.",
               "outputs" => [],
               "criterion_evidence" => [
                 %{
                   "criterion_id" => "compatibility",
                   "references" => [],
                   "note" => "A reported finding, without a native proof."
                 }
               ],
               "verification_limits" => "Documentation only; no native run."
             })

    assert {:ok, progress} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 1)
    assert {:ok, shared} = Custode.WorkAgreements.list(ctx.actor, ctx.claude.id, limit: 1)
    # Only the observation time changes between two independent reads.
    assert Map.drop(progress.work_agreements, ["observed_at", "agreements"]) ==
             Map.drop(shared, ["observed_at", "agreements"])

    [agreement] = progress.work_agreements["agreements"]
    [shared_agreement] = shared["agreements"]
    assert Map.delete(agreement, "observed_at") == Map.delete(shared_agreement, "observed_at")
    assert agreement["agreement_id"] == agreement_id
    assert agreement["current"]["intent"]["outcome"] == intent["outcome"]
    assert agreement["current"]["status"] == "submitted"
    assert agreement["current"]["resolution"] == nil
    assert agreement["evidence"] == "attributed_bookkeeping"
    assert progress.execution.active == nil
    assert :offline = Agents.live_provider(ctx.claude.id)
  end

  test "current attention exposes a budget rail even on an older conversation page", ctx do
    routines = Application.fetch_env!(:custode, :routines)

    Application.put_env(
      :custode,
      :routines,
      Enum.map(routines, fn routine ->
        if routine.id == ctx.claude.id,
          do: Map.put(routine, :daily_budget_usd, 1.0),
          else: routine
      end)
    )

    message!(ctx.claude.id, "older decision")
    message!(ctx.claude.id, "current decision")
    {:ok, initial} = ProjectProgress.read(ctx.actor, ctx.claude.id, limit: 1)
    refute initial.attention.kind == :rail_hit

    spend =
      %{
        agent_id: ctx.claude.id,
        cost_usd: 2.0,
        outcome: "turn",
        attribution_key: uid("progress-spend"),
        attribution_status: "legacy_unattributed"
      }
      |> Entry.changeset()
      |> Repo.insert!()

    assert {:ok, previous} =
             ProjectProgress.read(ctx.actor, ctx.claude.id,
               limit: 1,
               before: initial.conversation.before
             )

    assert previous.conversation.page == "older"
    assert previous.attention.kind == :rail_hit
    assert previous.attention.subject == ctx.claude.id
    assert previous.attention.group == :needs_you
    assert previous.blocker == nil
    refute Map.has_key?(previous.attention, :resolving)
    assert Repo.get!(Entry, spend.id) == spend
    assert :offline = Agents.live_provider(ctx.claude.id)
  end

  test "durable progress stays distinct from desired configuration and reading applies nothing",
       ctx do
    routine = Routine.get(ctx.codex.id)
    message = message!(routine.id, "Keep the next run manual.")
    job = provider_job!(routine, "completed", "previous-execution-revision")
    job = Repo.get!(Oban.Job, job.id)
    {:ok, arc} = ConversationArcs.prepare(routine, :operator)
    wake = wake!(routine.id)

    gate =
      Repo.insert!(%Gate{
        agent_id: routine.id,
        kind: "approval",
        action_id: uid("approval"),
        detail: "May I publish this release?",
        status: "open"
      })

    assert :offline = Agents.live_provider(routine.id)

    assert {:ok, progress} = ProjectProgress.read(ctx.actor, routine.id)
    assert progress.execution.active == nil
    assert progress.execution.applied == nil
    assert progress.execution.desired.config_revision == Routine.execution_revision(routine)
    assert [turn] = progress.execution.turns
    assert turn.id == job.id
    assert turn.provider == "codex"
    assert turn.model == "captured-model"
    assert turn.config_revision == "previous-execution-revision"
    assert progress.continuity.current.arc_id == arc.arc_id
    assert progress.pending_wake.wake_id == wake.wake_id
    assert progress.pending_wake.blocked_by == "paused"
    assert progress.blocker.kind == :approval
    assert progress.blocker.detail =~ gate.detail
    refute Map.has_key?(progress.blocker, :resolving)
    assert is_binary(Jason.encode!(progress))

    assert Repo.get!(Oban.Job, job.id) == job
    assert Repo.get!(InboxWake, routine.id) == wake
    assert Repo.get!(Gate, gate.id) == gate
    assert OperatorMessages.get(message.message_id) == message
    assert :offline = Agents.live_provider(routine.id)

    ConversationArcs.rotate(routine.id, "operator")
    {:ok, replacement} = ConversationArcs.prepare(routine, :operator)
    assert {:ok, reread} = ProjectProgress.read(identity(ctx.caretaker.id), routine.id)
    assert reread.project == progress.project
    assert reread.conversation == progress.conversation
    assert reread.continuity.current.arc_id == replacement.arc_id
    refute replacement.arc_id == arc.arc_id
    assert Repo.get!(InboxWake, routine.id) == wake
  end

  defp fixture(role, provider) do
    %{
      id: uid("progress-#{role}-#{provider}"),
      role: role,
      provider: provider,
      workspace: tmp_workspace!(),
      cron: :manual,
      prompt: "inspect project evidence"
    }
  end

  defp identity(id), do: %{kind: :routine, id: id}

  defp message!(target, prompt, actor \\ @operator) do
    {:ok, message, :created} =
      OperatorMessages.submit(
        target,
        prompt,
        [actor: actor, idempotency_key: uid("private-key")],
        fn _message -> {:ok, :queued} end
      )

    message
  end

  defp update!(row, attrs), do: row |> Ecto.Changeset.change(attrs) |> Repo.update!()

  defp change_role!(id, role) do
    routines = Application.fetch_env!(:custode, :routines)

    Application.put_env(
      :custode,
      :routines,
      Enum.map(routines, fn routine ->
        if routine.id == id, do: %{routine | role: role}, else: routine
      end)
    )
  end

  defp provider_job!(routine, state, revision) do
    worker = if routine.provider == :codex, do: ObanCodex.Agent.Job, else: ObanClaude.Agent.Job

    %{
      "prompt" => "captured turn",
      "model" => "captured-model",
      "working_dir" => routine.working_dir
    }
    |> Oban.Job.new(
      worker: worker,
      queue: :agents,
      meta: %{
        "agent_id" => routine.id,
        "config_revision" => revision,
        "agent_generation" => Ecto.UUID.generate(),
        "agent_turn_id" => Ecto.UUID.generate()
      }
    )
    |> Ecto.Changeset.change(state: state)
    |> Repo.insert!()
  end

  defp peer!(sender, recipient, body) do
    %PeerMessage{}
    |> PeerMessage.changeset(%{
      sender: sender,
      recipient: recipient,
      kind: "fyi",
      subject: "Private",
      body: body,
      idempotency_key: uid("peer"),
      correlation_id: Ecto.UUID.generate()
    })
    |> Repo.insert!()
  end

  defp wake!(id) do
    now = DateTime.utc_now()

    %{
      routine_id: id,
      wake_id: Ecto.UUID.generate(),
      state: "pending",
      reason: "inbox_activity",
      first_note_at: now,
      last_note_at: now,
      due_at: now,
      blocked_by: "paused"
    }
    |> InboxWake.create_changeset()
    |> Repo.insert!()
  end
end
