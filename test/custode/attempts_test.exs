defmodule Custode.AttemptsTest do
  use ExUnit.Case, async: false

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundle,
    ContextBundles,
    Mission,
    Repo,
    RoleBinding,
    SpendLedger,
    WorkItem,
    WorkItems
  }

  alias Custode.Workflow.{Results, Run}

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-attempts-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "ContextBundle validation is explicit and every acceptance-sensitive input changes its digest",
       %{artifact_dir: artifact_dir} do
    {_mission, work_item} = insert_work!("context")
    base = context_body(work_item)

    assert {:error, {:missing_context_components, ["workspace_revision"]}} =
             ContextBundles.create(
               work_item.work_item_id,
               Map.delete(base, "workspace_revision"),
               artifact_dir: artifact_dir
             )

    baseline = ContextBundles.digest(base)

    for key <- ~w(
          objective
          acceptance
          policy
          recipe
          prior_evidence
          external_revision
          workspace_revision
        ) do
      changed = Map.update!(base, key, &changed_value/1)
      refute ContextBundles.digest(changed) == baseline, "#{key} must affect the digest"

      refute ContextBundles.component_digests(changed)[key] ==
               ContextBundles.component_digests(base)[key]
    end
  end

  test "ContextBundle bodies are file-backed, verified, and reused by digest", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("bundle")
    body = context_body(work_item)

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(work_item.work_item_id, body,
               artifact_dir: artifact_dir,
               provenance: %{compiler: "test"}
             )

    assert bundle.mission.mission_id == mission.mission_id
    assert bundle.artifact.kind == "context_bundle"
    assert bundle.artifact.media_type == "application/json"
    assert bundle.artifact.size_bytes == File.stat!(bundle.artifact.location).size
    assert bundle.artifact.digest == Artifacts.digest(File.read!(bundle.artifact.location))
    assert {:ok, ^body} = ContextBundles.body(bundle.context_bundle_id)

    assert {:ok, {:existing, same}} =
             ContextBundles.create(work_item.work_item_id, body, artifact_dir: artifact_dir)

    assert same.context_bundle_id == bundle.context_bundle_id
    assert Repo.aggregate(ContextBundle, :count) == 1
    assert Repo.aggregate(Artifact, :count) == 1
  end

  test "deterministic and model Attempts share provenance and outcome shape", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("executor-shape")
    bundle = insert_bundle!(work_item, artifact_dir)

    deterministic =
      insert_attempt!(work_item, bundle, %{
        attempt_id: "attempt-deterministic",
        executor_kind: "deterministic",
        provider: "local",
        profile: "mix-test",
        recipe_version: "1"
      })

    model =
      insert_attempt!(work_item, bundle, %{
        attempt_id: "attempt-model",
        executor_kind: "model",
        provider: "claude",
        profile: "sonnet-low",
        recipe_version: "1"
      })

    for attempt <- [deterministic, model] do
      assert Map.keys(attempt.provenance) |> Enum.sort() == ["executor", "role_binding"]

      assert Map.keys(attempt.provenance["executor"]) |> Enum.sort() ==
               ["kind", "profile", "provider", "recipe_version"]

      assert {:ok, finished} =
               Attempts.finish(attempt.attempt_id, %{
                 state: "succeeded",
                 usage: %{duration_ms: 25},
                 outcome: %{kind: "evidence", result: "passed"}
               })

      assert finished.state == "succeeded"
      assert finished.outcome == %{"kind" => "evidence", "result" => "passed"}
      assert finished.usage == %{"duration_ms" => 25}
    end
  end

  test "physical retries reuse one Attempt and preserve first logical usage", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("retry")
    bundle = insert_bundle!(work_item, artifact_dir)
    attrs = attempt_attrs(work_item, bundle, attempt_id: "attempt-retry", oban_job_id: 44)

    assert {:ok, {:created, created}} = Attempts.create(attrs)
    assert {:ok, {:existing, duplicate}} = Attempts.create(attrs)
    assert duplicate.id == created.id

    assert {:ok, {:existing, same_job}} =
             attrs
             |> Map.put(:attempt_id, "different-delivery-id")
             |> Attempts.create()

    assert same_job.id == created.id
    assert Repo.aggregate(Attempt, :count) == 1

    assert {:ok, running} = Attempts.start(created.attempt_id, %{oban_job_id: 44})
    assert {:ok, retried} = Attempts.start(created.attempt_id, %{oban_job_id: 44})
    assert retried.started_at == running.started_at

    assert {:ok, finished} =
             Attempts.finish(created.attempt_id, %{
               state: "succeeded",
               usage: %{input_tokens: 10, output_tokens: 4},
               outcome: %{kind: "answer", digest: "first"}
             })

    assert {:ok, repeated} =
             Attempts.finish(created.attempt_id, %{
               state: "failed",
               usage: %{input_tokens: 999},
               outcome: %{kind: "duplicate"},
               error_class: "late_callback"
             })

    assert repeated.id == finished.id
    assert repeated.state == "succeeded"
    assert repeated.usage == %{"input_tokens" => 10, "output_tokens" => 4}
    assert repeated.outcome == %{"kind" => "answer", "digest" => "first"}
  end

  test "failed Attempt retains opaque continuation and never creates a failed WorkItem state", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("failure")
    bundle = insert_bundle!(work_item, artifact_dir)
    attempt = insert_attempt!(work_item, bundle, %{attempt_id: "attempt-failure"})

    assert {:ok, failed} =
             Attempts.finish(attempt.attempt_id, %{
               state: "failed",
               usage: %{cost_usd: 0.25},
               outcome: %{kind: "provider_failure"},
               error_class: "provider_error",
               error_details: %{retryable: true},
               provider_continuation: %{session_id: "opaque-provider-token"}
             })

    assert failed.provider_continuation == %{"session_id" => "opaque-provider-token"}
    assert failed.error_class == "provider_error"
    assert WorkItems.get(work_item.work_item_id).state == "ready"
  end

  test "semantic repair is a new causally linked Attempt", %{artifact_dir: artifact_dir} do
    {_mission, work_item} = insert_work!("repair")
    bundle = insert_bundle!(work_item, artifact_dir)
    previous = insert_attempt!(work_item, bundle, %{attempt_id: "attempt-before-repair"})

    assert {:error, {:attempt_nonterminal, "queued"}} =
             Attempts.repair(previous.attempt_id, attempt_attrs(work_item, bundle))

    {:ok, previous} =
      Attempts.finish(previous.attempt_id, %{
        state: "partial",
        usage: %{},
        outcome: %{kind: "verification", failures: ["one"]}
      })

    assert {:ok, {:created, repair}} =
             Attempts.repair(
               previous.attempt_id,
               attempt_attrs(work_item, bundle,
                 attempt_id: "attempt-repair",
                 recipe_version: "2"
               )
             )

    assert repair.id != previous.id
    assert repair.caused_by_attempt.attempt_id == previous.attempt_id
    assert repair.recipe_version == "2"
  end

  test "creation rejects stale WorkItem versions and cross-Mission or retired bindings", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("guards")
    bundle = insert_bundle!(work_item, artifact_dir)

    assert {:error, {:stale_work_item, %{expected: 2, observed: 1}}} =
             Attempts.create(attempt_attrs(work_item, bundle, expected_work_item_version: 2))

    other_binding = insert_binding!(insert_mission!("other"), "other-binding")

    assert {:error, :role_binding_mission_mismatch} =
             Attempts.create(
               attempt_attrs(work_item, bundle, role_binding_id: other_binding.binding_id)
             )

    retired = insert_binding!(mission, "retired-binding", "retired")

    assert {:error, :role_binding_retired} =
             Attempts.create(
               attempt_attrs(work_item, bundle, role_binding_id: retired.binding_id)
             )
  end

  test "an Attempt remains explainable from durable context after process state is gone", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("explain")
    binding = insert_binding!(mission, "reviewer")
    bundle = insert_bundle!(work_item, artifact_dir)

    attempt =
      insert_attempt!(work_item, bundle, %{
        attempt_id: "attempt-explain",
        role_binding_id: binding.binding_id,
        provider_continuation: %{conversation: "opaque"}
      })

    assert {:ok, explanation} = Attempts.explain(attempt.attempt_id)
    assert explanation.attempt_id == attempt.attempt_id
    assert explanation.context_body == context_body(work_item)
    assert explanation.context_bundle.digest == bundle.digest
    assert explanation.provenance["role_binding"]["role_template_version"] == "1"
  end

  test "Artifacts require a stable identity and enforce producer scope", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("artifact")
    bundle = insert_bundle!(work_item, artifact_dir)
    producer = insert_attempt!(work_item, bundle, %{attempt_id: "attempt-artifact-producer"})

    assert {:error, changeset} =
             Artifacts.create(%{
               work_item_id: work_item.work_item_id,
               kind: "external_snapshot",
               media_type: "application/json",
               location: "github://issue/363",
               size_bytes: 0
             })

    assert {"or external_identity is required", _} = changeset.errors[:digest]

    assert {:ok, artifact} =
             Artifacts.create(%{
               work_item_id: work_item.work_item_id,
               kind: "external_snapshot",
               external_identity: "github:genagent/custode:issue:363:rev:1",
               media_type: "application/json",
               location: "github://genagent/custode/issues/363",
               size_bytes: 0,
               producer_attempt_id: producer.attempt_id,
               provenance: %{source: "github"},
               retention: %{policy: "mission"}
             })

    assert artifact.digest == nil
    assert artifact.external_identity =~ "issue:363"
    assert artifact.producer_attempt.attempt_id == producer.attempt_id
    assert artifact.mission.mission_id == work_item.mission.mission_id

    {_other_mission, other_work_item} = insert_work!("other-artifact")

    assert {:error, :producer_work_item_mismatch} =
             Artifacts.create(%{
               work_item_id: other_work_item.work_item_id,
               producer_attempt_id: producer.attempt_id,
               kind: "review",
               external_identity: "review:other",
               media_type: "text/plain",
               location: "review://other",
               size_bytes: 0
             })
  end

  test "current spend derives provenance dimensions from its Attempt", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("spend")
    binding = insert_binding!(mission, "spender")
    bundle = insert_bundle!(work_item, artifact_dir)

    attempt =
      insert_attempt!(work_item, bundle, %{
        attempt_id: "attempt-spend",
        role_binding_id: binding.binding_id,
        provenance: %{"active_phase" => "implementing"}
      })

    assert :ok =
             SpendLedger.record("legacy-agent", 0.5, "turn",
               model: "sonnet",
               attempt_id: attempt.attempt_id
             )

    entry = Repo.one!(SpendLedger.Entry)
    assert entry.agent_id == "legacy-agent"
    assert entry.model == "sonnet"
    assert entry.attempt_id == attempt.attempt_id
    assert entry.work_item_id == work_item.work_item_id
    assert entry.mission_id == work_item.mission.mission_id
    assert entry.provider == "claude"
    assert entry.legacy_routine_id == nil
    assert entry.role_binding_id == binding.binding_id
    assert entry.executor_kind == "model"
    assert entry.workflow_phase == "implementing"
    assert entry.attribution_status == "attempt"
  end

  test "workflow runs and node results retain WorkItem and Attempt links", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("workflow-links")
    bundle = insert_bundle!(work_item, artifact_dir)
    attempt = insert_attempt!(work_item, bundle, %{attempt_id: "attempt-workflow-links"})

    run =
      Run.start(
        "run-attempt-links",
        "test-workflow",
        "genagent/custode",
        "inspect",
        %{},
        nil,
        work_item.work_item_id
      )

    assert run.work_item_id == work_item.work_item_id

    assert {:ok, running} =
             Attempts.start(attempt.attempt_id, %{workflow_run_id: run.run_id})

    assert running.workflow_run_id == run.run_id

    result =
      Results.put(%{
        workflow_run: run.run_id,
        workflow: run.workflow,
        stage: "inspect",
        node_name: "one",
        args_hash: "hash",
        result: %{ok: true},
        attempt_id: attempt.attempt_id
      })

    assert result.attempt_id == attempt.attempt_id
    assert Results.fetch(run.run_id, "one", "hash").attempt_id == attempt.attempt_id
  end

  test "telemetry carries authoritative Attempt, WorkItem, Mission, and provider dimensions", %{
    artifact_dir: artifact_dir
  } do
    {_mission, work_item} = insert_work!("telemetry-spend")
    bundle = insert_bundle!(work_item, artifact_dir)

    attempt =
      insert_attempt!(work_item, bundle, %{
        attempt_id: "attempt-telemetry",
        provenance: %{"active_phase" => "implementing"}
      })

    assert :ok =
             SpendLedger.handle_event(
               [:oban_claude, :run, :exception],
               %{cost_usd: 0.75},
               %{
                 job: %{
                   meta: %{
                     "agent_id" => "legacy-agent",
                     "attempt_id" => attempt.attempt_id,
                     "work_item_id" => work_item.work_item_id,
                     "mission_id" => work_item.mission.mission_id
                   }
                 },
                 args: %{"model" => "sonnet"}
               },
               nil
             )

    entry = Repo.one!(SpendLedger.Entry)
    assert entry.outcome == "failed"
    assert entry.attempt_id == attempt.attempt_id
    assert entry.work_item_id == work_item.work_item_id
    assert entry.mission_id == work_item.mission.mission_id
    assert entry.provider == "claude"
    assert entry.legacy_routine_id == nil
    assert entry.attribution_status == "attempt"
  end

  test "an active Attempt is an explicit Mission archive obligation", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("archive-attempt")
    bundle = insert_bundle!(work_item, artifact_dir)
    attempt = insert_attempt!(work_item, bundle, %{attempt_id: "attempt-archive"})

    work_item
    |> Ecto.Changeset.change(
      state: "completed",
      phase: "done",
      completed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    assert {:error,
            {:active_obligation, %{kind: "attempt", id: "attempt-archive", status: "queued"}}} =
             Custode.Missions.archive(mission.mission_id, "archive-attempt-test")

    assert {:ok, _finished} =
             Attempts.finish(attempt.attempt_id, %{
               state: "cancelled",
               usage: %{},
               outcome: %{kind: "cancelled"}
             })

    assert {:ok, archived} =
             Custode.Missions.archive(mission.mission_id, "archive-attempt-test")

    assert archived.status == "archived"
  end

  test "archived Missions reject new context, artifact, and Attempt provenance", %{
    artifact_dir: artifact_dir
  } do
    {mission, work_item} = insert_work!("archived-writes")
    bundle = insert_bundle!(work_item, artifact_dir)

    mission
    |> Ecto.Changeset.change(status: "archived", archived_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:error, :mission_archived} =
             ContextBundles.create(work_item.work_item_id, context_body(work_item),
               artifact_dir: artifact_dir
             )

    assert {:error, :mission_archived} =
             Artifacts.create(%{
               work_item_id: work_item.work_item_id,
               kind: "review",
               external_identity: "review:archived",
               media_type: "text/plain",
               location: "review://archived",
               size_bytes: 0
             })

    assert {:error, :mission_archived} =
             Attempts.create(attempt_attrs(work_item, bundle))
  end

  defp insert_bundle!(work_item, artifact_dir) do
    assert {:ok, {:created, bundle}} =
             ContextBundles.create(work_item.work_item_id, context_body(work_item),
               artifact_dir: artifact_dir
             )

    bundle
  end

  defp insert_attempt!(work_item, bundle, overrides) do
    assert {:ok, {:created, attempt}} =
             work_item
             |> attempt_attrs(bundle)
             |> Map.merge(overrides)
             |> Attempts.create()

    attempt
  end

  defp attempt_attrs(work_item, bundle, overrides \\ []) do
    Map.merge(
      %{
        attempt_id: Ecto.UUID.generate(),
        work_item_id: work_item.work_item_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "model",
        provider: "claude",
        profile: "sonnet-low",
        recipe_version: "1",
        expected_work_item_version: work_item.version
      },
      Map.new(overrides)
    )
  end

  defp context_body(work_item) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{"ref" => work_item.policy_ref},
      "recipe" => %{"name" => "issue-work", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => 363, "updated_at" => "2026-07-29"},
      "workspace_revision" => %{"git" => "abc123"}
    }
  end

  defp changed_value(value) when is_binary(value), do: value <> "-changed"
  defp changed_value(value) when is_list(value), do: value ++ [%{"changed" => true}]
  defp changed_value(value) when is_map(value), do: Map.put(value, "changed", true)

  defp insert_work!(suffix) do
    mission = insert_mission!(suffix)

    work_item =
      %{
        work_item_id: "work-#{suffix}",
        mission_id: mission.id,
        kind: "github_issue_delivery",
        workflow_version: 1,
        objective: "Implement #{suffix}",
        acceptance_criteria: %{"tests" => "pass"},
        state: "ready",
        phase: "eligible",
        priority: 1,
        policy_ref: "policy:default",
        source: "test",
        external_key: "issue-#{suffix}",
        version: 1
      }
      |> WorkItem.create_changeset()
      |> Repo.insert!()
      |> Repo.preload(:mission)

    {mission, work_item}
  end

  defp insert_mission!(suffix) do
    %{
      mission_id: "mission-#{suffix}",
      key: "test:#{suffix}",
      purpose: "Test #{suffix}",
      lifecycle: "persistent",
      status: "active"
    }
    |> Mission.create_changeset()
    |> Repo.insert!()
  end

  defp insert_binding!(mission, suffix, lifecycle \\ "active") do
    %{
      binding_id: "binding-#{suffix}",
      mission_id: mission.id,
      key: suffix,
      template_key: "reviewer",
      template_version: "1",
      authority_source: "database",
      scoped_overrides: %{},
      grants: %{},
      lifecycle: lifecycle,
      provenance: %{},
      retired_at: if(lifecycle == "retired", do: DateTime.utc_now())
    }
    |> RoleBinding.create_changeset()
    |> Repo.insert!()
  end

  defp cleanup! do
    Repo.query!("DELETE FROM workflow_node_results")
    Repo.query!("DELETE FROM workflow_runs")
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(Custode.WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(Custode.MissionTarget)
    Repo.delete_all(Custode.OperationCall)
    Repo.delete_all(Mission)
  end
end
