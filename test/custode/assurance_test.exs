defmodule Custode.AssuranceTest do
  use ExUnit.Case, async: false
  import Custode.TestHelpers

  alias Custode.{
    Assurance,
    OwnerReviews,
    Repo,
    Repository,
    SubjectDocumentBridge,
    SubjectDocuments
  }

  alias Custode.Assurance.Evaluator
  alias Custode.CLI.{AssuranceRead, Client}
  alias Custode.MCP.{AssuranceTools, CallContext, ToolPolicy}

  defmodule FakeChecks do
    @moduledoc false
    def checks_for_ref(_owner, _repository, revision) do
      send(
        Application.fetch_env!(:custode, :assurance_checks_test_pid),
        {:checks_requested, self(), revision}
      )

      receive do
        :release_checks ->
          {:ok, [%{id: 42, name: "fixture-check", status: "completed", conclusion: "success"}]}
      after
        5_000 -> {:error, :fixture_timeout}
      end
    end
  end

  @human %{kind: :operator, id: "assurance-judge"}
  @sha String.duplicate("a", 40)

  setup do
    owner = routine_fixture!(tmp_workspace!(), %{repo: "acme/" <> uid("assurance")})

    assignment = %{
      "id" => uid("assignment"),
      "owner_id" => owner.id,
      "judge_id" => @human.id,
      "max_rounds" => 3,
      "criteria" => ["The frozen review reports no findings."],
      "policy" => %{"predicates" => [predicate("review", "owner_review", "self_reported")]}
    }

    put_env!(:assurance_assignments, [assignment])

    request = %{
      "case_id" => uid("case"),
      "assignment_id" => assignment["id"],
      "objective" => "Review this bounded change.",
      "input" => "Pinned input.",
      "artifact" => %{"kind" => "repository", "repository" => owner.repo, "revision" => @sha}
    }

    on_exit(fn ->
      Repo.delete_all(Assurance.Row)
      Repo.delete_all(OwnerReviews.Row)
    end)

    %{owner: owner, assignment: assignment, request: request, id: request["case_id"]}
  end

  test "opt-in owner assignment, operator recording, frozen inputs and exact replay", ctx do
    assert {:error, :operator_required} =
             Assurance.open(%{kind: :routine, id: ctx.owner.id}, ctx.request)

    assert {:error, :assignment_unavailable} =
             Assurance.open(@human, %{ctx.request | "assignment_id" => "unknown"})

    tasks = for _ <- 1..2, do: Task.async(fn -> Assurance.open(@human, ctx.request) end)
    assert [{:ok, first}, {:ok, same}] = Enum.map(tasks, &Task.await/1)
    assert same == first
    assert {:ok, ^first} = Assurance.open(@human, ctx.request)
    assert first["current"]["objective_revision"] == Assurance.digest(ctx.request["objective"])
    assert first["current"]["criteria"] == ctx.assignment["criteria"]
    assert first["current"]["generation"] == 1

    assert {:error, :idempotency_conflict} =
             Assurance.open(@human, %{ctx.request | "input" => "changed"})

    assert {:ok, projection} = Assurance.read(%{kind: :routine, id: ctx.owner.id}, ctx.id)
    assert projection["evaluation"]["missing"] == ["review", "designated_judge"]
    assert projection["effect_authority"] == "none"

    assert {:error, :owner_scope_unavailable} =
             Assurance.read(%{kind: :routine, id: "other"}, ctx.id)

    assert {:error, :owner_scope_unavailable} =
             Assurance.read(%{kind: :sub_agent, id: ctx.owner.id}, ctx.id)

    unbound = put_in(ctx.request, ["artifact", "repository"], "acme/another")

    assert {:error, :artifact_scope_unavailable} =
             Assurance.open(@human, %{unbound | "case_id" => uid("bad")})
  end

  test "host custody never promotes provider prose; source payload and trust labels are refused",
       ctx do
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    review_id = review_fixture(ctx, "clean")

    request =
      capture_request("review", %{"kind" => "owner_review", "review_id" => review_id, "slot" => 1})

    assert {:ok, receipt} = Assurance.capture(@human, ctx.id, request)
    assert receipt["custody_class"] == "host_observed"
    assert receipt["claim_class"] == "self_reported"
    assert receipt["execution"] == nil
    assert "native_provider_run_identity_unavailable" in receipt["limits"]

    assert {:error, :invalid_arguments} =
             Assurance.capture(
               @human,
               ctx.id,
               Map.put(request, "trust_class", "independently_reproduced")
             )

    spoofed = put_in(request, ["source", "result"], %{"verdict" => "clean"})
    assert {:error, :invalid_arguments} = Assurance.capture(@human, ctx.id, spoofed)
    assert {:ok, ^receipt} = Assurance.capture(@human, ctx.id, request)
    changed = put_in(request, ["source", "slot"], 2)
    assert {:error, :idempotency_conflict} = Assurance.capture(@human, ctx.id, changed)
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert projection["evaluation"]["satisfied"] == ["review"]
    assert projection["evaluation"]["missing"] == ["designated_judge"]
    refute Map.has_key?(hd(projection["evidence"]), "snapshot")
  end

  test "designated judge is required; contradictions win over passed reviews without effects",
       ctx do
    jobs_before = Repo.aggregate(Oban.Job, :count)
    assert {:ok, _case} = Assurance.open(@human, ctx.request)

    for verdict <- ~w(clean findings) do
      id = review_fixture(ctx, verdict)

      assert {:ok, _receipt} =
               Assurance.capture(
                 @human,
                 ctx.id,
                 capture_request("review", %{
                   "kind" => "owner_review",
                   "review_id" => id,
                   "slot" => 1
                 })
               )
    end

    assert {:error, :designated_judge_required} =
             Assurance.judge(%{kind: :operator, id: "other"}, ctx.id, judgment())

    assert {:ok, _judge} = Assurance.judge(@human, ctx.id, judgment())
    event = event_request()
    assert {:ok, decision} = Assurance.decide(@human, ctx.id, event)
    assert decision["status"] == "rejected"
    assert decision["contradictory"] == ["review"]
    assert decision["satisfied"] == ["designated_judge"]
    assert length(decision["evidence_ids"]) == 3
    assert decision["effect_authority"] == "none"
    assert {:ok, ^decision} = Assurance.decide(@human, ctx.id, event)
    assert Repo.aggregate(Oban.Job, :count) == jobs_before
  end

  test "artifact/input/policy revisions invalidate evidence, with bounded generations and stable history",
       ctx do
    assert {:ok, first} = Assurance.open(@human, ctx.request)
    id = review_fixture(ctx, "clean")

    old_receipt =
      capture_request("review", %{"kind" => "owner_review", "review_id" => id, "slot" => 1})

    assert {:ok, receipt} = Assurance.capture(@human, ctx.id, old_receipt)
    assert {:ok, _judge} = Assurance.judge(@human, ctx.id, judgment())
    assert {:ok, accepted} = Assurance.decide(@human, ctx.id, event_request())
    assert accepted["status"] == "accepted"

    changed_assignment = %{ctx.assignment | "criteria" => ["A new criterion."]}
    put_env!(:assurance_assignments, [changed_assignment])
    assert {:ok, drift} = Assurance.read(@human, ctx.id)
    assert drift["evaluation"]["status"] == "escalated"
    assert drift["evaluation"]["satisfied"] == []
    assert "current_policy" in drift["evaluation"]["missing"]
    assert hd(drift["decisions"]) == accepted

    revision = revise_request(ctx.request, 1)
    revision = put_in(revision, ["artifact", "revision"], String.duplicate("b", 40))
    revision = Map.put(revision, "input", "Changed instructions.")
    assert {:ok, second} = Assurance.revise(@human, ctx.id, revision)
    assert {:ok, ^second} = Assurance.revise(@human, ctx.id, revision)
    refute second["case_revision"] == first["current"]["case_revision"]
    refute second["artifact_revision"] == first["current"]["artifact_revision"]
    refute second["policy_digest"] == first["current"]["policy_digest"]
    assert second["generation"] == 2
    assert {:ok, ^receipt} = Assurance.capture(@human, ctx.id, old_receipt)
    stale = %{old_receipt | "request_id" => uid("stale")}
    assert {:error, :stale_generation} = Assurance.capture(@human, ctx.id, stale)
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert projection["evaluation"]["satisfied"] == []
    assert projection["evaluation"]["missing"] == ["review", "designated_judge"]
    assert length(projection["attempts"]) == 2
    assert {:ok, _third} = Assurance.revise(@human, ctx.id, revise_request(ctx.request, 2))

    assert {:error, :revision_round_bound} =
             Assurance.revise(@human, ctx.id, revise_request(ctx.request, 3))
  end

  test "native review run and provider identity remain missing for independent predicates", ctx do
    independent =
      put_in(ctx.assignment, ["policy", "predicates"], [
        predicate("review", "owner_review", "self_reported", true)
      ])

    put_env!(:assurance_assignments, [independent])
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    id = review_fixture(ctx, "clean")

    assert {:ok, receipt} =
             Assurance.capture(
               @human,
               ctx.id,
               capture_request("review", %{
                 "kind" => "owner_review",
                 "review_id" => id,
                 "slot" => 1
               })
             )

    assert receipt["execution"] == nil
    assert {:ok, _judge} = Assurance.judge(@human, ctx.id, judgment())
    assert {:ok, decision} = Assurance.decide(@human, ctx.id, event_request())
    assert decision["status"] == "escalated"
    assert decision["missing"] == ["review"]
  end

  test "unbound review prose and changed publication receipts cannot satisfy exact artifact predicates",
       ctx do
    root = tmp_workspace!()
    root_id = uid("root")

    put_env!(:subject_roots, [
      %{
        id: root_id,
        path: root,
        subject: "Assurance",
        grants: [%{kind: :routine, id: ctx.owner.id, read_paths: "all"}]
      }
    ])

    on_exit(fn ->
      SubjectDocumentBridge.reset()
      Repo.delete_all(SubjectDocuments.Operation)
      Repo.delete_all(SubjectDocumentBridge.Binding)
    end)

    publication_id = uid("publication")

    assert {:ok, publication} =
             SubjectDocuments.invoke(@human, %{
               "action" => "create",
               "root_id" => root_id,
               "path" => "report.md",
               "content" => "Bounded report.",
               "request_id" => publication_id
             })

    assignment =
      put_in(ctx.assignment, ["policy", "predicates"], [
        predicate("presence", "document", "host_observed")
      ])

    put_env!(:assurance_assignments, [assignment])

    request = %{
      ctx.request
      | "artifact" => %{
          "kind" => "document",
          "root_id" => root_id,
          "path" => "report.md",
          "revision" => publication["revision"]
        }
    }

    assert {:ok, _case} = Assurance.open(@human, request)
    capture = capture_request("presence", %{"kind" => "document", "request_id" => publication_id})
    assert {:ok, observed} = Assurance.capture(@human, ctx.id, capture)
    assert observed["outcome"] == "passed"
    File.write!(Path.join(root, "report.md"), "Externally changed.")

    assert {:ok, changed} =
             Assurance.capture(@human, ctx.id, %{capture | "request_id" => uid("reread")})

    assert changed["outcome"] == "failed"
    assert changed["missing_bindings"] == []
    assert {:ok, decision} = Assurance.decide(@human, ctx.id, event_request())
    assert decision["contradictory"] == ["presence"]
  end

  test "captured execution identity belongs to the frozen job, without becoming quality evidence",
       ctx do
    meta = %{
      "agent_id" => ctx.owner.id,
      "agent_generation" => uid("generation"),
      "agent_turn_id" => uid("turn"),
      "config_revision" => Custode.Routine.execution_revision(ctx.owner)
    }

    job =
      Repo.insert!(%Oban.Job{
        worker: "ObanClaude.Agent.Job",
        queue: "agents",
        args: %{"model" => "fixture"},
        meta: meta,
        attempt: 1,
        state: "completed"
      })

    assignment =
      put_in(ctx.assignment, ["policy", "predicates"], [
        predicate("run", "execution", "host_observed")
      ])

    put_env!(:assurance_assignments, [assignment])
    assert {:ok, record} = Assurance.open(@human, Map.put(ctx.request, "producer_job_id", job.id))
    assert record["current"]["producer"]["provider"] == "claude"
    assert record["current"]["producer"]["job_id"] == job.id

    assert {:ok, receipt} =
             Assurance.capture(
               @human,
               ctx.id,
               capture_request("run", %{"kind" => "execution", "job_id" => job.id})
             )

    assert receipt["outcome"] == "passed"
    assert receipt["claim_class"] == "host_observed"
    assert "captured_job_is_not_artifact_verification" in receipt["limits"]

    assert {:ok, wrong} =
             Assurance.capture(
               @human,
               ctx.id,
               capture_request("run", %{"kind" => "execution", "job_id" => job.id + 1_000_000})
             )

    assert wrong["outcome"] == "unknown"
    assert wrong["missing_bindings"] == ["frozen_producer_execution"]
  end

  test "review prose mentioning a head cannot substitute for the exact frozen envelope", ctx do
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    id = review_fixture(ctx, "clean")
    row = Repo.get!(OwnerReviews.Row, id)
    record = put_in(row.record, ["request", "evidence"], "Reviewed " <> @sha)
    row |> Ecto.Changeset.change(record: record) |> Repo.update!()

    assert {:ok, receipt} =
             Assurance.capture(
               @human,
               ctx.id,
               capture_request("review", %{
                 "kind" => "owner_review",
                 "review_id" => id,
                 "slot" => 1
               })
             )

    assert receipt["missing_bindings"] == ["review_input_revision"]
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert "review" in projection["evaluation"]["missing"]

    assert hd(projection["evaluation"]["predicates"])["excluded_evidence"] == [
             %{"id" => receipt["id"], "reasons" => ["source_bindings"]}
           ]
  end

  test "source observation cannot admit a stale generation and unbound repository attestations remain unknown",
       ctx do
    put_env!(:repo_ops, FakeChecks)
    put_env!(:assurance_checks_test_pid, self())
    assert :ok = Repository.ensure_served(ctx.owner.repo, ctx.owner.id)
    on_exit(fn -> Repository.stop_serving(ctx.owner.repo) end)

    assignment =
      put_in(ctx.assignment, ["policy", "predicates"], [
        predicate("check", "repository_check", "external_attested")
      ])

    put_env!(:assurance_assignments, [assignment])
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    request = capture_request("check", %{"kind" => "repository_check", "name" => "fixture-check"})
    capture = Task.async(fn -> Assurance.capture(@human, ctx.id, request) end)
    assert_receive {:checks_requested, server, @sha}

    revision =
      put_in(revise_request(ctx.request, 1), ["artifact", "revision"], String.duplicate("b", 40))

    assert {:ok, _attempt} = Assurance.revise(@human, ctx.id, revision)
    send(server, :release_checks)
    assert {:error, :stale_generation} = Task.await(capture)
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert projection["evidence"] == []

    request = %{request | "request_id" => uid("current-check"), "generation" => 2}
    capture = Task.async(fn -> Assurance.capture(@human, ctx.id, request) end)
    assert_receive {:checks_requested, server, requested_head}
    assert requested_head == String.duplicate("b", 40)
    send(server, :release_checks)
    assert {:ok, receipt} = Task.await(capture)
    assert receipt["claim_class"] == "unverified_attestation"
    assert receipt["outcome"] == "unknown"
    assert receipt["missing_bindings"] == ["configured_issuer", "check_head_revision"]
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert "check" in projection["evaluation"]["missing"]
  end

  test "MCP and CLI read the same shared operation and cannot record evidence", ctx do
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    assert ToolPolicy.fetch("assurance_read") == {:ok, :read}
    frame = %CallContext{assigns: %{custode_identity: @human}}
    assert {:ok, projection} = Assurance.read(@human, ctx.id)
    assert tool_json(AssuranceTools.Read.execute(%{case_id: ctx.id}, frame)) == projection
    assert {:ok, ^projection} = Client.call("assurance_read", %{case_id: ctx.id})
    assert AssuranceRead.__info__(:functions) |> Keyword.has_key?(:run)

    assert tool_error(AssuranceTools.Read.execute(%{case_id: ctx.id}, %CallContext{})) =~
             "unauthenticated"
  end

  test "SQLite connection restart preserves complete attempts, receipts and decisions", ctx do
    assert {:ok, _case} = Assurance.open(@human, ctx.request)
    id = review_fixture(ctx, "clean")

    assert {:ok, _receipt} =
             Assurance.capture(
               @human,
               ctx.id,
               capture_request("review", %{
                 "kind" => "owner_review",
                 "review_id" => id,
                 "slot" => 1
               })
             )

    assert {:ok, _judge} = Assurance.judge(@human, ctx.id, judgment())
    assert {:ok, _decision} = Assurance.decide(@human, ctx.id, event_request())
    assert {:ok, _revision} = Assurance.revise(@human, ctx.id, revise_request(ctx.request, 1))
    assert {:ok, expected} = Assurance.read(@human, ctx.id)
    rows = Repo.all(Assurance.Row)
    reviews = Repo.all(OwnerReviews.Row)
    path = Path.join(tmp_workspace!(), "restart.db")
    original = Repo.get_dynamic_repo()
    {:ok, first} = Repo.start_link(name: nil, database: path, pool_size: 1, log: false)
    Repo.put_dynamic_repo(first)

    try do
      Ecto.Migrator.run(Repo, Custode.Migrations.path(), :up, all: true, log: false)

      for row <- rows,
          do:
            Repo.insert!(
              Ecto.Changeset.change(
                %Assurance.Row{},
                Map.from_struct(row) |> Map.drop([:__meta__])
              )
            )

      for row <- reviews,
          do:
            Repo.insert!(
              Ecto.Changeset.change(
                %OwnerReviews.Row{},
                Map.from_struct(row) |> Map.drop([:__meta__])
              )
            )

      GenServer.stop(first)
      {:ok, second} = Repo.start_link(name: nil, database: path, pool_size: 1, log: false)
      Repo.put_dynamic_repo(second)

      try do
        assert {:ok, ^expected} = Assurance.read(@human, ctx.id)
        assert length(Repo.all(Assurance.Row)) == length(rows)

        assert Repo.all(OwnerReviews.Row) |> Enum.map(& &1.record) ==
                 Enum.map(reviews, & &1.record)
      after
        GenServer.stop(second)
      end
    after
      Repo.put_dynamic_repo(original)
      if Process.alive?(first), do: GenServer.stop(first)
    end
  end

  test "synthetic evaluator fixtures enforce issuer/run/provider/revision independence and reproduction class",
       ctx do
    # Synthetic receipts exercise the evaluator only, never the production recorder.
    assert {:ok, record} = Assurance.open(@human, ctx.request)
    attempt = record["current"]

    producer = %{
      "actor" => "owner",
      "provider" => "claude",
      "run_id" => "producer-run",
      "revision" => "producer-config"
    }

    policy = %{
      "predicates" => [predicate("verify", "owner_review", "independently_reproduced", true)]
    }

    attempt = Map.merge(attempt, %{"producer" => producer, "policy" => policy})

    verifier = %{
      "actor" => "verifier",
      "provider" => "codex",
      "run_id" => "verifier-run",
      "revision" => "verifier-config"
    }

    receipt = %{
      "id" => "synthetic",
      "predicate" => "verify",
      "kind" => "owner_review",
      "issuer" => "custode.assurance.v1",
      "claim_class" => "independently_reproduced",
      "execution" => verifier,
      "missing_bindings" => [],
      "outcome" => "passed",
      "binding" => Map.take(attempt, ~w(case_revision artifact_revision policy_digest generation))
    }

    assert Evaluator.evaluate(attempt, [receipt], attempt["policy_digest"])["satisfied"] == [
             "verify"
           ]

    for invalid <- [
          Map.put(receipt, "issuer", "model"),
          Map.put(receipt, "claim_class", "self_reported"),
          put_in(receipt, ["execution", "provider"], nil),
          put_in(receipt, ["execution", "revision"], nil),
          put_in(receipt, ["execution", "actor"], producer["actor"]),
          put_in(receipt, ["execution", "provider"], producer["provider"]),
          put_in(receipt, ["execution", "run_id"], producer["run_id"]),
          put_in(receipt, ["binding", "artifact_revision"], "stale"),
          put_in(receipt, ["binding", "policy_digest"], "stale"),
          put_in(receipt, ["binding", "generation"], 0),
          Map.put(receipt, "missing_bindings", ["issuer"])
        ] do
      assert "verify" in Evaluator.evaluate(attempt, [invalid], attempt["policy_digest"])[
               "missing"
             ]
    end

    contradiction = %{receipt | "id" => "synthetic-failed", "outcome" => "failed"}
    result = Evaluator.evaluate(attempt, [receipt, contradiction], attempt["policy_digest"])
    assert result["contradictory"] == ["verify"]
    refute "verify" in result["satisfied"]
  end

  defp predicate(name, source, class, independent \\ false),
    do: %{
      "name" => name,
      "sources" => [source],
      "classes" => [class],
      "independent" => independent
    }

  defp event_request(generation \\ 1),
    do: %{"request_id" => uid("event"), "generation" => generation}

  defp judgment,
    do:
      Map.merge(event_request(), %{
        "outcome" => "passed",
        "reason" => "Reviewed this exact frozen case."
      })

  defp capture_request(predicate, source),
    do: Map.merge(event_request(), %{"predicate" => predicate, "source" => source})

  defp revise_request(request, generation),
    do: request |> Map.take(~w(objective input artifact)) |> Map.merge(event_request(generation))

  defp review_fixture(ctx, verdict) do
    {:ok, input} = Assurance.review_input(@human, ctx.id)
    id = uid("synthetic-review")

    child = %{
      "slot" => 1,
      "job_id" => 999_999_999,
      "attempt_id" => uid("synthetic-attempt"),
      "status" => "completed",
      "route" => %{"provider" => "claude"},
      "result" => %{"verdict" => verdict},
      "settlement" => "synthetic_fixture"
    }

    record = %{
      "request" => %{"evidence" => input},
      "children" => [child],
      "cancel_requested" => false
    }

    Repo.insert!(%OwnerReviews.Row{
      request_id: id,
      owner_id: ctx.owner.id,
      fingerprint: "synthetic",
      record: record
    })

    id
  end
end
