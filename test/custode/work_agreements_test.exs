defmodule Custode.WorkAgreementsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers
  import Ecto.Query, only: [from: 2]

  alias Custode.{
    AgentAuthorizationSnapshot,
    OperatorMessage,
    PeerMessage,
    Repo,
    Routine,
    WorkAgreements
  }

  setup do
    owner = routine("agreement-owner", :assistant)
    other = routine("agreement-other", :assistant)
    caretaker = routine("agreement-caretaker", :caretaker)
    routines = [owner, other, caretaker]
    ids = Enum.map(routines, & &1.id)
    put_env!(:routines, routines)
    assert Application.get_env(:custode, :oban_queues) == []
    assert Application.get_env(:custode, :scheduler_autostart) == false

    on_exit(fn ->
      agreement_ids =
        Repo.all(
          from(row in "work_agreements", where: row.routine_id in ^ids, select: row.agreement_id)
        )

      Repo.delete_all(
        from(row in "work_agreement_records", where: row.agreement_id in ^agreement_ids)
      )

      Repo.delete_all(from(row in "work_agreements", where: row.agreement_id in ^agreement_ids))
      Repo.delete_all(from(row in AgentAuthorizationSnapshot, where: row.routine_id in ^ids))
    end)

    %{
      owner: owner,
      other: other,
      caretaker: caretaker,
      routines: routines,
      actor: actor(owner),
      human: %{kind: :operator, id: uid("agreement-human")},
      intent: intent()
    }
  end

  test "a fresh process reconstructs changed intent, a blocked step, evidence and human resolution without dispatch",
       ctx do
    baseline = dispatch_counts()
    create = create_attrs(ctx)

    assert {:ok, created} =
             Task.async(fn -> WorkAgreements.create(ctx.human, create) end) |> Task.await()

    id = created["agreement_id"]
    assert {:ok, ^id} = Ecto.UUID.cast(id)
    assert created["revision"] == 1
    assert created["sequence"] == 1
    assert created["kind"] == "created"
    assert created["duplicate"] == false
    assert created["recorded_by"]["id"] == ctx.human.id

    assert {:ok, first_checkpoint} =
             WorkAgreements.checkpoint(ctx.actor, id, checkpoint_attrs(1, ctx.human))

    assert first_checkpoint["revision"] == 1
    assert first_checkpoint["sequence"] == 2

    revised_intent = Map.put(ctx.intent, "outcome", "Compare both options including their limits")

    assert {:ok, revised} =
             WorkAgreements.revise(ctx.human, id, revision_attrs(1, revised_intent))

    assert revised["revision"] == 2
    assert revised["sequence"] == 3

    assert {:ok, checkpoint} =
             WorkAgreements.checkpoint(ctx.actor, id, checkpoint_attrs(2, ctx.human))

    assert {:ok, submitted} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(2, ctx.intent))

    assert {:ok, before_resolution} = WorkAgreements.read(ctx.human, id)
    assert before_resolution["current"]["status"] == "submitted"
    assert before_resolution["current"]["resolution"] == nil

    assert {:ok, resolved} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(2, submitted["record_id"]))

    assert {:ok, recovered} =
             Task.async(fn -> WorkAgreements.read(ctx.actor, id) end) |> Task.await()

    assert recovered["current_revision"] == 2
    assert recovered["last_sequence"] == 6
    assert recovered["current"]["intent"] == revised_intent
    assert recovered["current"]["status"] == "accepted"
    assert recovered["current"]["checkpoint"]["record_id"] == checkpoint["record_id"]
    assert recovered["current"]["submission"]["record_id"] == submitted["record_id"]
    assert recovered["current"]["resolution"]["record_id"] == resolved["record_id"]

    assert recovered["current"]["resolution"]["payload"]["submission_id"] ==
             submitted["record_id"]

    assert recovered["current"]["resolution"]["recorded_by"]["kind"] == "operator"

    [blocker] = recovered["current"]["checkpoint"]["payload"]["blockers"]
    assert blocker["resolver"] == %{"kind" => "operator", "id" => ctx.human.id}
    assert blocker["references"] == [reference("operator_message", "operator-request")]

    records = recovered["history"]["records"]
    assert Enum.map(records, & &1["sequence"]) == [6, 5, 4, 3, 2, 1]
    assert Enum.any?(records, &(&1["record_id"] == first_checkpoint["record_id"]))
    assert {:ok, _, _} = DateTime.from_iso8601(recovered["observed_at"])
    assert {:ok, _} = Jason.encode(recovered)
    assert dispatch_counts() == baseline
  end

  test "late results retain their old revision and cannot replace a current accepted result",
       ctx do
    id = create!(ctx)
    revised_intent = Map.put(ctx.intent, "assignment_id", uid("replacement-assignment"))
    assert {:ok, _} = WorkAgreements.revise(ctx.human, id, revision_attrs(1, revised_intent))

    assert {:ok, current} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(2, revised_intent))

    assert {:ok, accepted} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(2, current["record_id"]))

    assert {:ok, late} = WorkAgreements.submit(ctx.actor, id, submission_attrs(1, ctx.intent))
    assert late["revision"] == 1

    assert {:error, :assignment_mismatch} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(1, revised_intent))

    assert {:error, :submission_revision_mismatch} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(2, late["record_id"]))

    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["current_revision"] == 2
    assert view["current"]["status"] == "accepted"
    assert view["current"]["submission"]["record_id"] == current["record_id"]
    assert view["current"]["resolution"]["record_id"] == accepted["record_id"]
    assert Enum.any?(view["history"]["records"], &(&1["record_id"] == late["record_id"]))

    assert {:error, :unknown_revision} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(3, ctx.intent))
  end

  test "a changed intent cannot inherit acceptance while a checkpoint does not change intent",
       ctx do
    id = create!(ctx)

    assert {:ok, submitted} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(1, ctx.intent))

    assert {:ok, accepted} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(1, submitted["record_id"]))

    assert {:ok, checkpoint} =
             WorkAgreements.checkpoint(ctx.actor, id, checkpoint_attrs(1, ctx.human))

    assert checkpoint["revision"] == 1
    assert {:ok, before_revision} = WorkAgreements.read(ctx.human, id)
    assert before_revision["current"]["status"] == "accepted"
    assert before_revision["current"]["resolution"]["record_id"] == accepted["record_id"]

    changed =
      Map.put(ctx.intent, "criteria", [%{"id" => "new", "text" => "Include failure modes"}])

    assert {:ok, _} = WorkAgreements.revise(ctx.human, id, revision_attrs(1, changed))
    assert {:ok, after_revision} = WorkAgreements.read(ctx.human, id)
    assert after_revision["current_revision"] == 2
    assert after_revision["current"]["intent"] == changed
    assert after_revision["current"]["status"] == "open"
    assert after_revision["current"]["submission"] == nil
    assert after_revision["current"]["resolution"] == nil

    assert Enum.any?(
             after_revision["history"]["records"],
             &(&1["record_id"] == accepted["record_id"])
           )
  end

  test "two concurrent revisions cannot overwrite the same current intent", ctx do
    id = create!(ctx)

    results =
      for outcome <- ["First proposed scope", "Second proposed scope"] do
        Task.async(fn ->
          intent = Map.put(ctx.intent, "outcome", outcome)
          WorkAgreements.revise(ctx.human, id, revision_attrs(1, intent))
        end)
      end
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :revision_conflict})) == 1
    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["current_revision"] == 2
    assert view["last_sequence"] == 2
    assert length(view["history"]["records"]) == 2

    assert {:error, :revision_conflict} =
             WorkAgreements.checkpoint(ctx.actor, id, checkpoint_attrs(1, ctx.human))

    assert {:error, :revision_conflict} =
             WorkAgreements.revise(ctx.human, id, revision_attrs(1, ctx.intent))
  end

  test "exact retries recover every original operation receipt before checking current revision",
       ctx do
    create = create_attrs(ctx)
    assert {:ok, created} = WorkAgreements.create(ctx.human, create)
    id = created["agreement_id"]
    checkpoint = checkpoint_attrs(1, ctx.human)
    submission = submission_attrs(1, ctx.intent)
    assert {:ok, checked} = WorkAgreements.checkpoint(ctx.actor, id, checkpoint)
    assert {:ok, submitted} = WorkAgreements.submit(ctx.actor, id, submission)
    resolution = resolution_attrs(1, submitted["record_id"])
    assert {:ok, resolved} = WorkAgreements.resolve(ctx.human, id, resolution)
    revision = revision_attrs(1, Map.put(ctx.intent, "outcome", "New scope after acceptance"))
    assert {:ok, revised} = WorkAgreements.revise(ctx.human, id, revision)

    for {operation, args, original} <- [
          {:create, [ctx.human, create], created},
          {:checkpoint, [ctx.actor, id, checkpoint], checked},
          {:submit, [ctx.actor, id, submission], submitted},
          {:resolve, [ctx.human, id, resolution], resolved},
          {:revise, [ctx.human, id, revision], revised}
        ] do
      assert {:ok, replayed} = apply(WorkAgreements, operation, args)
      assert replayed == Map.put(original, "duplicate", true)
    end

    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["current_revision"] == 2
    assert view["last_sequence"] == 5
    assert view["current"]["status"] == "open"
  end

  test "an authorized create retry recovers its receipt after the owner leaves the roster", ctx do
    attrs = create_attrs(ctx)
    assert {:ok, created} = WorkAgreements.create(ctx.human, attrs)
    put_env!(:routines, Enum.reject(ctx.routines, &(&1.id == ctx.owner.id)))

    assert {:ok, recovered} = WorkAgreements.create(ctx.human, attrs)
    assert recovered == Map.put(created, "duplicate", true)
    assert {:ok, view} = WorkAgreements.read(ctx.human, created["agreement_id"])
    assert view["current"]["intent"] == ctx.intent
    assert view["last_sequence"] == 1

    assert {:error, :unknown_routine} =
             WorkAgreements.create(ctx.human, Map.put(attrs, "request_id", uid("new-create")))

    assert {:error, :unknown_routine} =
             WorkAgreements.revise(
               ctx.human,
               created["agreement_id"],
               revision_attrs(1, ctx.intent)
             )

    assert {:error, :unknown_routine} = WorkAgreements.read(ctx.actor, created["agreement_id"])
  end

  test "oversized JSON integers are rejected before binding mutation revisions or history cursors",
       ctx do
    id = create!(ctx)
    huge = Jason.decode!("18446744073709551616")

    for {operation, attrs} <- [
          {:revise, revision_attrs(huge, ctx.intent)},
          {:checkpoint, checkpoint_attrs(huge, ctx.human)},
          {:submit, submission_attrs(huge, ctx.intent)},
          {:resolve, resolution_attrs(huge, Ecto.UUID.generate())}
        ] do
      assert {:error, :invalid_arguments} =
               apply(WorkAgreements, operation, [ctx.human, id, attrs])
    end

    assert {:error, :invalid_arguments} =
             WorkAgreements.read(ctx.human, id, before_sequence: huge)

    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["current_revision"] == 1
    assert view["last_sequence"] == 1
  end

  test "concurrent exact create retries retain one agreement and one receipt", ctx do
    attrs = create_attrs(ctx)

    results =
      1..5
      |> Task.async_stream(fn _ -> WorkAgreements.create(ctx.human, attrs) end,
        max_concurrency: 5,
        timeout: 5_000
      )
      |> Enum.map(fn {:ok, {:ok, receipt}} -> receipt end)

    assert [id] = Enum.uniq_by(results, & &1["agreement_id"]) |> Enum.map(& &1["agreement_id"])
    assert length(Enum.uniq_by(results, & &1["record_id"])) == 1
    assert Enum.count(results, &(&1["duplicate"] == false)) == 1
    assert Enum.count(results, &(&1["duplicate"] == true)) == 4
    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["last_sequence"] == 1
  end

  test "retry keys bind the actor, operation, target and full payload", ctx do
    id = create!(ctx)
    other_id = create!(ctx)
    attrs = checkpoint_attrs(1, ctx.human)
    assert {:ok, original} = WorkAgreements.checkpoint(ctx.human, id, attrs)

    assert {:error, :idempotency_conflict} =
             WorkAgreements.checkpoint(
               ctx.human,
               id,
               Map.put(attrs, "summary", "Changed meaning")
             )

    assert {:error, :idempotency_conflict} = WorkAgreements.checkpoint(ctx.human, other_id, attrs)

    revision = revision_attrs(1, ctx.intent) |> Map.put("request_id", attrs["request_id"])
    assert {:error, :idempotency_conflict} = WorkAgreements.revise(ctx.human, id, revision)

    assert {:ok, different_actor} = WorkAgreements.checkpoint(ctx.actor, id, attrs)
    refute different_actor["record_id"] == original["record_id"]
    assert different_actor["recorded_by"]["id"] == ctx.actor.id
    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["last_sequence"] == 3
  end

  test "canonical keys reconcile retries while unknown or colliding fields cannot alter intent",
       ctx do
    attrs = create_attrs(ctx)

    atom_keys = %{
      request_id: attrs["request_id"],
      routine_id: attrs["routine_id"],
      intent: ctx.intent
    }

    assert {:ok, original} = WorkAgreements.create(ctx.human, atom_keys)
    assert {:ok, same} = WorkAgreements.create(ctx.human, attrs)
    assert same == Map.put(original, "duplicate", true)

    for invalid <- [
          Map.put(attrs, :request_id, uid("duplicate-key")),
          Map.put(attrs, "recorded_by", %{"kind" => "operator", "id" => "forged"}),
          put_in(attrs, ["intent", "gate_approval"], true),
          put_in(attrs, ["intent", "criteria"], ctx.intent["criteria"] ++ ctx.intent["criteria"])
        ] do
      assert {:error, :invalid_arguments} = WorkAgreements.create(ctx.human, invalid)
    end

    assert {:ok, view} = WorkAgreements.read(ctx.human, original["agreement_id"])
    assert view["current"]["intent"] == ctx.intent
    assert view["last_sequence"] == 1
  end

  test "submission requires criterion evidence and explicit verification limits but may report no outputs",
       ctx do
    id = create!(ctx)
    attrs = submission_attrs(1, ctx.intent) |> Map.put("outputs", [])

    for invalid <- [
          Map.delete(attrs, "criterion_evidence"),
          Map.put(attrs, "criterion_evidence", []),
          Map.delete(attrs, "verification_limits"),
          Map.put(attrs, "verification_limits", " "),
          Map.put(
            attrs,
            "criterion_evidence",
            attrs["criterion_evidence"] ++ attrs["criterion_evidence"]
          )
        ] do
      assert {:error, :invalid_arguments} = WorkAgreements.submit(ctx.actor, id, invalid)
    end

    assert {:error, :assignment_mismatch} =
             WorkAgreements.submit(
               ctx.actor,
               id,
               Map.put(attrs, "assignment_id", "other-assignment")
             )

    unknown =
      put_in(attrs, ["criterion_evidence"], [
        %{"criterion_id" => "unknown", "references" => [], "note" => "No finding"}
      ])

    assert {:error, :unknown_criterion} = WorkAgreements.submit(ctx.actor, id, unknown)

    assert {:ok, submitted} = WorkAgreements.submit(ctx.actor, id, attrs)

    assert {:ok, _} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(1, submitted["record_id"]))

    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["last_sequence"] == 3
    assert view["current"]["submission"]["payload"]["outputs"] == []
    assert view["current"]["status"] == "accepted"
  end

  test "one submission receives one exact human resolution", ctx do
    id = create!(ctx)

    assert {:ok, submitted} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(1, ctx.intent))

    attrs = resolution_attrs(1, submitted["record_id"])
    assert {:ok, original} = WorkAgreements.resolve(ctx.human, id, attrs)
    assert {:ok, replayed} = WorkAgreements.resolve(ctx.human, id, attrs)
    assert replayed == Map.put(original, "duplicate", true)

    conflicting = resolution_attrs(1, submitted["record_id"]) |> Map.put("outcome", "rejected")
    assert {:error, :already_resolved} = WorkAgreements.resolve(ctx.human, id, conflicting)
    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["last_sequence"] == 3
    assert view["current"]["resolution"]["record_id"] == original["record_id"]
  end

  test "a later submission needs its own resolution even when the preceding result was accepted",
       ctx do
    id = create!(ctx)
    assert {:ok, first} = WorkAgreements.submit(ctx.actor, id, submission_attrs(1, ctx.intent))

    assert {:ok, _} =
             WorkAgreements.resolve(ctx.human, id, resolution_attrs(1, first["record_id"]))

    for outcome <- ["changes_requested", "rejected"] do
      assert {:ok, next} = WorkAgreements.submit(ctx.actor, id, submission_attrs(1, ctx.intent))
      assert {:ok, pending} = WorkAgreements.read(ctx.human, id)
      assert pending["current"]["status"] == "submitted"
      assert pending["current"]["resolution"] == nil
      assert pending["current"]["submission"]["record_id"] == next["record_id"]

      attrs = resolution_attrs(1, next["record_id"]) |> Map.put("outcome", outcome)
      assert {:ok, resolved} = WorkAgreements.resolve(ctx.human, id, attrs)
      assert {:ok, view} = WorkAgreements.read(ctx.human, id)
      assert view["current"]["status"] == outcome
      assert view["current"]["resolution"]["record_id"] == resolved["record_id"]
    end
  end

  test "owner and caretaker bookkeeping never grants helper or human decision authority", ctx do
    assert {:error, :forbidden} = WorkAgreements.create(ctx.actor, create_attrs(ctx))
    id = create!(ctx)

    assert {:error, :forbidden} =
             WorkAgreements.revise(ctx.actor, id, revision_attrs(1, ctx.intent))

    foreign = create_attrs(ctx) |> Map.put("routine_id", ctx.other.id)
    caretaker = actor(ctx.caretaker)
    assert {:error, :forbidden} = WorkAgreements.create(ctx.actor, foreign)
    assert {:ok, managed} = WorkAgreements.create(caretaker, foreign)
    managed_id = managed["agreement_id"]
    assert {:ok, _} = WorkAgreements.read(caretaker, id)
    assert {:ok, _} = WorkAgreements.revise(caretaker, id, revision_attrs(1, ctx.intent))
    assert {:error, :forbidden} = WorkAgreements.read(ctx.actor, managed_id)

    assert {:error, :forbidden} =
             WorkAgreements.checkpoint(caretaker, id, checkpoint_attrs(2, ctx.human))

    assert {:error, :forbidden} =
             WorkAgreements.submit(caretaker, id, submission_attrs(2, ctx.intent))

    assert {:ok, submitted} =
             WorkAgreements.submit(ctx.actor, id, submission_attrs(2, ctx.intent))

    for unauthorized <- [ctx.actor, caretaker, %{kind: :sub_agent, id: ctx.owner.id}] do
      assert {:error, :forbidden} =
               WorkAgreements.resolve(
                 unauthorized,
                 id,
                 resolution_attrs(2, submitted["record_id"])
               )
    end

    for unauthorized <- [actor(ctx.other), %{kind: :sub_agent, id: ctx.owner.id}] do
      assert {:error, :forbidden} = WorkAgreements.read(unauthorized, id)

      assert {:error, :forbidden} =
               WorkAgreements.checkpoint(unauthorized, id, checkpoint_attrs(2, ctx.human))
    end

    for malformed <- [nil, %{}, %{kind: :operator}, %{kind: :operator, id: ""}] do
      assert {:error, :unauthenticated} = WorkAgreements.read(malformed, id)
      assert {:error, :unauthenticated} = WorkAgreements.create(malformed, create_attrs(ctx))
    end

    assert {:ok, view} = WorkAgreements.read(ctx.human, id)
    assert view["current"]["status"] == "submitted"
    assert view["current"]["resolution"] == nil
  end

  test "a desired roster promotion cannot change the captured authority of an active turn", ctx do
    id = create!(ctx)
    old = Routine.get(ctx.owner.id)
    revision = Routine.execution_revision(old)
    assert :ok = AgentAuthorizationSnapshot.put(old, revision)

    job =
      %{"prompt" => "retain captured agreement authority"}
      |> Oban.Job.new(
        worker: ObanClaude.Agent.Job,
        queue: :agents,
        meta: %{
          "agent_id" => ctx.owner.id,
          "agent_generation" => Ecto.UUID.generate(),
          "agent_turn_id" => Ecto.UUID.generate(),
          "config_revision" => revision
        }
      )
      |> Ecto.Changeset.change(state: "suspended")
      |> Repo.insert!()

    on_exit(fn -> Repo.delete!(Repo.reload!(job)) end)

    put_env!(
      :routines,
      Enum.map(ctx.routines, fn
        %{id: id} = routine when id == ctx.owner.id -> %{routine | role: :caretaker}
        routine -> routine
      end)
    )

    foreign = create_attrs(ctx) |> Map.put("routine_id", ctx.other.id)
    assert {:error, :forbidden} = WorkAgreements.create(ctx.actor, foreign)

    assert {:ok, checkpoint} =
             WorkAgreements.checkpoint(ctx.actor, id, checkpoint_attrs(1, ctx.human))

    assert checkpoint["recorded_by"]["execution_revision"] == revision

    job |> Ecto.Changeset.change(state: "completed") |> Repo.update!()
    assert {:ok, promoted} = WorkAgreements.create(ctx.actor, foreign)
    refute promoted["recorded_by"]["execution_revision"] == revision
  end

  test "durable reads paginate retained records and reject another routine's list cursor", ctx do
    ids = for _ <- 1..3, do: create!(ctx)
    [first | _] = ids
    assert {:ok, _} = WorkAgreements.checkpoint(ctx.actor, first, checkpoint_attrs(1, ctx.human))
    assert {:ok, _} = WorkAgreements.revise(ctx.human, first, revision_attrs(1, ctx.intent))
    assert {:ok, page} = WorkAgreements.read(ctx.human, first, limit: 2)
    assert Enum.map(page["history"]["records"], & &1["sequence"]) == [3, 2]
    assert page["history"]["has_more"]

    assert {:ok, older} =
             WorkAgreements.read(ctx.human, first,
               limit: 2,
               before_sequence: page["history"]["before_sequence"]
             )

    assert Enum.map(older["history"]["records"], & &1["sequence"]) == [1]
    refute older["history"]["has_more"]
    assert older["current_revision"] == 2

    assert {:ok, listing} = WorkAgreements.list(ctx.human, ctx.owner.id, limit: 2)
    assert length(listing["agreements"]) == 2
    assert listing["has_more"]

    assert {:ok, last_page} =
             WorkAgreements.list(ctx.actor, ctx.owner.id,
               before_id: listing["before_id"],
               limit: 2
             )

    assert length(last_page["agreements"]) == 1
    refute last_page["has_more"]
    listed_ids = Enum.map(listing["agreements"] ++ last_page["agreements"], & &1["agreement_id"])
    assert Enum.sort(listed_ids) == Enum.sort(ids)

    assert {:error, :invalid_cursor} =
             WorkAgreements.list(ctx.human, ctx.other.id, before_id: listing["before_id"])
  end

  defp create!(ctx) do
    assert {:ok, receipt} = WorkAgreements.create(ctx.human, create_attrs(ctx))
    receipt["agreement_id"]
  end

  defp create_attrs(ctx) do
    %{"request_id" => uid("create"), "routine_id" => ctx.owner.id, "intent" => ctx.intent}
  end

  defp revision_attrs(revision, intent) do
    %{"request_id" => uid("revise"), "expected_revision" => revision, "intent" => intent}
  end

  defp checkpoint_attrs(revision, human) do
    %{
      "request_id" => uid("checkpoint"),
      "expected_revision" => revision,
      "summary" => "Compared the available evidence; a bounded step remains blocked.",
      "next_steps" => [
        %{"id" => "compare", "text" => "Compare the remaining option", "references" => []}
      ],
      "blockers" => [
        %{
          "id" => "access",
          "text" => "The operator must provide the missing source",
          "resolver" => %{"kind" => "operator", "id" => human.id},
          "references" => [reference("operator_message", "operator-request")]
        }
      ],
      "decisions" => [
        %{
          "id" => "scope",
          "text" => "Keep the comparison read-only",
          "resolver" => %{"kind" => "operator", "id" => human.id},
          "references" => []
        }
      ]
    }
  end

  defp submission_attrs(revision, intent) do
    %{
      "request_id" => uid("submit"),
      "agreement_revision" => revision,
      "assignment_id" => intent["assignment_id"],
      "summary" => "Compared the two options using the supplied source.",
      "outputs" => [reference("document", "comparison.md")],
      "criterion_evidence" => [
        %{
          "criterion_id" => "compare",
          "references" => [reference("document", "comparison.md")],
          "note" => "Both options are covered by the linked comparison."
        }
      ],
      "verification_limits" => "Fixture evidence only; no external execution was performed."
    }
  end

  defp resolution_attrs(revision, submission_id) do
    %{
      "request_id" => uid("resolve"),
      "expected_revision" => revision,
      "submission_id" => submission_id,
      "outcome" => "accepted",
      "reason" => "The linked result satisfies the current comparison criterion."
    }
  end

  defp intent do
    %{
      "outcome" => "Compare the two options",
      "criteria" => [
        %{"id" => "compare", "text" => "Compare both options against the same source"}
      ],
      "assignment_id" => uid("assignment"),
      "boundaries" => ["Read-only research; no external changes"],
      "request_references" => [reference("operator_message", "operator-request")],
      "inputs" => [reference("document", "source.md")],
      "expected_outputs" => [reference("document", "comparison.md")]
    }
  end

  defp reference(kind, value), do: %{"kind" => kind, "value" => value}
  defp actor(routine), do: %{kind: :routine, id: routine.id}

  defp routine(prefix, role) do
    %{
      id: uid(prefix),
      role: role,
      provider: :claude,
      cron: :manual,
      workspace: tmp_workspace!(),
      prompt: "Record bounded progress under normal authority",
      on_note: :ignore
    }
  end

  defp dispatch_counts do
    %{
      jobs: Repo.aggregate(Oban.Job, :count),
      operator_messages: Repo.aggregate(OperatorMessage, :count),
      peer_messages: Repo.aggregate(PeerMessage, :count)
    }
  end
end
