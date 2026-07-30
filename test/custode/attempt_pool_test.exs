defmodule Custode.AttemptPoolTest do
  use ExUnit.Case, async: false

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Artifact,
    Attempt,
    AttemptPool,
    Attempts,
    AttemptWorker,
    AttemptWorkerRegistry,
    ContextBundle,
    ContextBundles,
    GitHubIssueAttemptDispatcher,
    Mission,
    OperationCall,
    Repo,
    SpendLedger,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems,
    WorkProcess,
    WorkspaceLease
  }

  alias Custode.AttemptPool.Refusal

  defmodule Handler do
    def dispatch(attempt, job_id, options) do
      options
      |> Keyword.fetch!(:handler_fun)
      |> then(& &1.(attempt, job_id))
    end
  end

  setup do
    cleanup!()
    artifact_dir = Path.join(System.tmp_dir!(), "custode-attempt-pool-#{Ecto.UUID.generate()}")

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(artifact_dir)
    end)

    %{artifact_dir: artifact_dir}
  end

  test "worker declarations reject duplicate names and list deterministically" do
    first = worker!("zeta.worker")
    second = worker!("alpha.worker")

    assert {:ok, registry} = AttemptWorkerRegistry.new([first, second])

    assert Enum.map(AttemptWorkerRegistry.list(registry), & &1.name) ==
             ~w(alpha.worker zeta.worker)

    assert {:error, {:duplicate_attempt_worker, "zeta.worker"}} =
             AttemptWorkerRegistry.new([first, first])
  end

  test "matching checks executor, repository, tools, operations, and isolation", fixture do
    attempt = insert_model_attempt!("matching", fixture)
    insert_active_lease!(attempt)

    worker =
      worker!("restricted.claude",
        repositories: ["repository-42"],
        tools: ~w(Read Glob Grep Edit Write),
        isolation: ["owned_worktree"],
        features: ~w(cancellation heartbeat structured_output timeout)
      )

    registry = registry!([worker])

    assert {:ok, admission} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry,
               usage_fun: &zero_usage/1
             )

    assert admission.worker.name == worker.name
    assert admission.requirements.repository_id == "repository-42"
    assert admission.requirements.tools == ~w(Read Glob Grep Edit Write)
    assert admission.requirements.isolation == "owned_worktree"

    wrong_repository = %{worker | repositories: ["repository-99"]}
    wrong_tools = %{worker | tools: ["Read"]}
    wrong_isolation = %{worker | isolation: ["workspace_provisioning"]}

    for unavailable <- [wrong_repository, wrong_tools, wrong_isolation] do
      assert {:blocked, %Refusal{code: "no_eligible_worker"} = refusal} =
               AttemptPool.admit(attempt.attempt_id,
                 worker_registry: registry!([unavailable]),
                 usage_fun: &zero_usage/1
               )

      assert refusal.details["requirements"]["repository_id"] == "repository-42"
    end
  end

  test "the default pool selects the declared Codex worker", fixture do
    attempt =
      insert_model_attempt!("codex-worker", fixture,
        provider: "codex",
        profile: "gpt-5.6-codex"
      )

    insert_active_lease!(attempt)

    assert {:ok, admission} =
             AttemptPool.admit(attempt.attempt_id, usage_fun: &zero_usage/1)

    assert admission.worker.name == "local.codex"
    assert admission.requirements.provider == "codex"
  end

  test "spend and concurrency rails are deterministic before launch", fixture do
    attempt = insert_model_attempt!("rails", fixture)
    insert_active_lease!(attempt)
    registry = registry!([worker!("local.claude")])

    assert {:blocked, %Refusal{code: "spend_limit_reached"} = spend} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry,
               usage_fun: fn _routine -> %{cost_usd: 10.0, tokens: 25} end
             )

    assert spend.details["rail"] == "daily_budget_usd"
    assert spend.details["observed"] == 10.0
    assert spend.details["limit"] == 10.0

    assert {:retry, %Refusal{code: "concurrency_limit", retry_after_ms: 2_500} = capacity} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry,
               usage_fun: &zero_usage/1,
               active_count_fun: fn _worker, _attempt -> 1 end,
               capacity_retry_after_ms: 2_500
             )

    assert capacity.details == %{
             "active" => 1,
             "limit" => 1,
             "worker" => "local.claude"
           }
  end

  test "pinned work policy can only narrow spend, capacity, and posture", fixture do
    policy = %{
      posture: "auto",
      controls: %{
        budget: %{daily_budget_usd: 2.0, daily_budget_tokens: 1_000},
        execution: %{max_concurrency: 1}
      }
    }

    attempt = insert_model_attempt!("pinned-policy", fixture, work_policy: policy)
    insert_active_lease!(attempt)
    registry = registry!([worker!("local.claude", max_concurrency: 3)])

    assert {:blocked, %Refusal{code: "spend_limit_reached"} = spend} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry,
               usage_fun: fn _routine -> %{cost_usd: 2.0, tokens: 0} end
             )

    assert spend.details["limit"] == 2.0

    assert {:retry, %Refusal{code: "concurrency_limit"} = capacity} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry,
               usage_fun: &zero_usage/1,
               active_count_fun: fn _worker, _attempt -> 1 end
             )

    assert capacity.details["limit"] == 1
    assert capacity.details["worker_limit"] == 3
    assert capacity.details["policy_limit"] == 1

    ask =
      insert_model_attempt!("ask-policy", fixture,
        work_policy: %{posture: "ask", controls: policy.controls}
      )

    assert {:blocked, %Refusal{code: "work_policy_gate_required"}} =
             AttemptPool.admit(ask.attempt_id,
               worker_registry: registry,
               usage_fun: &zero_usage/1
             )
  end

  test "an expired lease blocks launch without invoking a handler", fixture do
    attempt = insert_model_attempt!("expired-lease", fixture)
    insert_active_lease!(attempt, expires_at: DateTime.add(DateTime.utc_now(), -1, :second))

    assert {:blocked, %Refusal{code: "workspace_lease_expired"}} =
             AttemptPool.admit(attempt.attempt_id,
               worker_registry: registry!([worker!("local.claude")]),
               usage_fun: &zero_usage/1
             )
  end

  test "process dispatch records a typed block when no worker is eligible", fixture do
    attempt = insert_model_attempt!("process-block", fixture)
    worker = worker!("restricted.claude", repositories: ["repository-99"])

    options = [
      enqueue: false,
      attempt_dispatcher: GitHubIssueAttemptDispatcher,
      worker_registry: registry!([worker]),
      usage_fun: &zero_usage/1
    ]

    delivery = claim!(attempt, options)

    assert {:discard, {:attempt_dispatch_refused, "no_eligible_worker"}} =
             WorkProcess.perform(
               delivery.event.event_id,
               attempt.work_item.work_item_id,
               attempt.work_item.version,
               501,
               options
             )

    blocked_attempt = Attempts.get(attempt.attempt_id)
    assert blocked_attempt.state == "blocked"
    assert blocked_attempt.error_class == "capability_mismatch"
    assert blocked_attempt.outcome["worker_pool"]["code"] == "no_eligible_worker"

    blocked_work = WorkItems.get(attempt.work_item.work_item_id)
    assert blocked_work.state == "blocked"
    assert blocked_work.phase == "implementation_ready"
    assert blocked_work.blocked_reason["worker_pool"]["code"] == "no_eligible_worker"
  end

  test "capacity retries the same queued Attempt and launches it when a slot opens", fixture do
    attempt = insert_model_attempt!("process-capacity", fixture)
    insert_active_lease!(attempt)
    test_pid = self()

    options = [
      enqueue: false,
      attempt_dispatcher: GitHubIssueAttemptDispatcher,
      worker_registry: registry!([worker!("local.claude")]),
      usage_fun: &zero_usage/1,
      active_count_fun: fn _worker, _attempt -> 1 end,
      capacity_retry_after_ms: 2_500,
      handler_fun: fn attrs, job_id ->
        attempt_id = attrs[:attempt_id] || attrs["attempt_id"]
        send(test_pid, {:launched, attempt_id, job_id})
        {:ok, _running} = Attempts.start(attempt_id, %{oban_job_id: job_id})
        :ok
      end
    ]

    delivery = claim!(attempt, options)

    assert {:snooze, 3} =
             WorkProcess.perform(
               delivery.event.event_id,
               attempt.work_item.work_item_id,
               attempt.work_item.version,
               502,
               options
             )

    assert Attempts.get(attempt.attempt_id).state == "queued"
    assert WorkItems.get(attempt.work_item.work_item_id).state == "ready"

    available =
      Keyword.put(options, :active_count_fun, fn _worker, _attempt -> 0 end)

    attempt_id = attempt.attempt_id

    assert :ok =
             WorkProcess.perform(
               delivery.event.event_id,
               attempt.work_item.work_item_id,
               attempt.work_item.version,
               502,
               available
             )

    assert_received {:launched, ^attempt_id, 502}
    assert Attempts.get(attempt.attempt_id).state == "running"
    assert WorkItems.get(attempt.work_item.work_item_id).active_attempt_id == attempt.attempt_id
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "dispatch rechecks policy, invokes one handler, and preserves the Attempt", fixture do
    attempt = insert_model_attempt!("dispatch", fixture)
    insert_active_lease!(attempt)
    test_pid = self()

    handler = fn attrs, job_id ->
      send(test_pid, {:dispatched, attrs.attempt_id, job_id})
      :ok
    end

    options = [
      worker_registry: registry!([worker!("local.claude")]),
      usage_fun: &zero_usage/1,
      active_count_fun: fn _worker, _attempt -> 0 end,
      handler_fun: handler
    ]

    attrs = %{attempt_id: attempt.attempt_id, command_kind: "implement"}
    attempt_id = attempt.attempt_id

    assert :ok = AttemptPool.dispatch(attrs, 77, options)
    assert_received {:dispatched, ^attempt_id, 77}
    assert Repo.aggregate(Attempt, :count) == 2

    assert {:error, :handler_refusal} =
             AttemptPool.dispatch(
               attrs,
               78,
               Keyword.put(options, :handler_fun, fn _attrs, _job_id ->
                 {:error, :handler_refusal}
               end)
             )

    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "cancellation is idempotent and keeps one Attempt identity", fixture do
    attempt = insert_model_attempt!("cancel", fixture)

    assert {:ok, cancellation} = AttemptPool.cancel(attempt.attempt_id, :operator)
    assert cancellation.attempt_id == attempt.attempt_id
    assert cancellation.status == :requested
    assert Attempts.get(attempt.attempt_id).state == "cancelled"

    assert {:ok, repeated} = AttemptPool.cancel(attempt.attempt_id, :operator)
    assert repeated.attempt_id == attempt.attempt_id
    assert repeated.status == :already_terminal
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "lost physical delivery blocks work while preserving Attempt provenance", fixture do
    attempt = insert_model_attempt!("lost", fixture)
    insert_active_lease!(attempt)
    set_active!(attempt)
    assert {:ok, running} = Attempts.start(attempt.attempt_id, %{oban_job_id: 999_999})
    original_provenance = running.provenance

    assert {:ok, [recovery]} = AttemptPool.reconcile()
    assert recovery.attempt_id == attempt.attempt_id
    assert recovery.reason.code == "worker_delivery_missing"

    failed = Attempts.get(attempt.attempt_id)
    assert failed.state == "failed"
    assert failed.error_class == "worker_lost"
    assert failed.provenance == original_provenance
    assert failed.outcome["kind"] == "worker_lost"

    blocked = WorkItems.get(attempt.work_item.work_item_id)
    assert blocked.state == "blocked"
    assert blocked.phase == "implementing"
    assert blocked.active_attempt_id == nil
    assert blocked.blocked_reason["code"] == "worker_lost"

    assert {:ok, []} = AttemptPool.reconcile()
    assert Repo.aggregate(Attempt, :count) == 2
  end

  test "reconciliation completes a worker-loss transition interrupted after Attempt finish",
       fixture do
    attempt = insert_model_attempt!("lost-transition", fixture)
    set_active!(attempt)
    assert {:ok, _running} = Attempts.start(attempt.attempt_id, %{oban_job_id: 999_998})

    proposal = %{
      state: "blocked",
      phase: "implementing",
      blocked_reason: %{
        code: "worker_lost",
        attempt_id: attempt.attempt_id
      },
      evidence: %{worker_pool: %{code: "worker_delivery_missing"}}
    }

    assert {:ok, _failed} =
             Attempts.finish(attempt.attempt_id, %{
               state: "failed",
               usage: %{},
               outcome: %{kind: "worker_lost", proposal: proposal},
               error_class: "worker_lost",
               error_details: %{code: "worker_delivery_missing"}
             })

    assert WorkItems.get(attempt.work_item.work_item_id).state == "active"
    assert {:ok, [recovery]} = AttemptPool.reconcile()
    assert recovery.attempt_id == attempt.attempt_id
    assert WorkItems.get(attempt.work_item.work_item_id).state == "blocked"
    assert {:ok, []} = AttemptPool.reconcile()
  end

  defp insert_model_attempt!(suffix, %{artifact_dir: artifact_dir}, options \\ []) do
    provider = Keyword.get(options, :provider, "claude")
    profile = Keyword.get(options, :profile, "sonnet:high")

    mission =
      %{
        mission_id: "mission-pool-#{suffix}",
        key: "pool:#{suffix}",
        purpose: "Pool test #{suffix}",
        lifecycle: "persistent",
        status: "active",
        budget_ref: "budget:test"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    work_item =
      %{
        work_item_id: "work-pool-#{suffix}",
        mission_id: mission.id,
        kind: "github_issue_to_merge",
        workflow_version: 1,
        objective: "Implement #{suffix}",
        acceptance_criteria: %{"tests" => "pass"},
        state: "ready",
        phase: "implementation_ready",
        priority: 1,
        policy_ref: "policy:test",
        source: "github",
        external_key: "github:repository-42:issue:#{suffix}",
        version: 1
      }
      |> WorkItem.create_changeset()
      |> Repo.insert!()
      |> Repo.preload(:mission)

    body = %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{
        "budget" => %{
          "max_budget_usd" => 2.0,
          "daily_budget_usd" => 10.0,
          "daily_budget_tokens" => 100_000,
          "max_turns" => 2,
          "timeout_ms" => 30_000
        }
      },
      "recipe" => %{"name" => "github_issue_implementation", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => suffix},
      "workspace_revision" => %{"repository_id" => "repository-42", "revision" => "abc123"},
      "capabilities" => %{
        "tools" => %{
          "allowed" => ~w(Read Glob Grep Edit Write),
          "disallowed" => ~w(Bash WebFetch WebSearch Task)
        },
        "operations" => []
      },
      "output_contract" => %{"kind" => "test"}
    }

    assert {:ok, {:created, bundle}} =
             ContextBundles.create(work_item.work_item_id, body, artifact_dir: artifact_dir)

    assert {:ok, {:created, preparation}} =
             Attempts.create(%{
               attempt_id: "attempt-pool-preparation-#{suffix}",
               work_item_id: work_item.work_item_id,
               context_bundle_id: bundle.context_bundle_id,
               executor_kind: "deterministic",
               provider: "custode",
               profile: "workspace-git",
               recipe_version: "1",
               expected_work_item_version: work_item.version,
               command_kind: "prepare_workspace",
               provenance: %{
                 purpose: "workspace_preparation",
                 legacy_routine_id: "routine-pool"
               }
             })

    assert {:ok, {:created, model}} =
             Attempts.create(%{
               attempt_id: "attempt-pool-model-#{suffix}",
               work_item_id: work_item.work_item_id,
               context_bundle_id: bundle.context_bundle_id,
               executor_kind: "model",
               provider: provider,
               profile: profile,
               recipe_version: "1",
               expected_work_item_version: work_item.version,
               command_kind: "implement",
               provenance:
                 %{
                   purpose: "github_issue_implementation",
                   legacy_routine_id: "routine-pool"
                 }
                 |> maybe_put(:work_policy, Keyword.get(options, :work_policy))
             })

    Map.put(model, :preparation_attempt, preparation)
  end

  defp insert_active_lease!(attempt, overrides \\ []) do
    now = DateTime.utc_now()

    attrs =
      %{
        lease_id: "lease:#{attempt.attempt_id}",
        mission_id: attempt.work_item.mission.id,
        work_item_id: attempt.work_item.id,
        attempt_id: attempt.preparation_attempt.id,
        repository_id: "repository-42",
        repository_path: "/tmp/repository-42",
        workspace_identity: "workspace:#{attempt.attempt_id}",
        workspace_path: "/tmp/workspace-#{attempt.attempt_id}",
        branch: "codex/#{attempt.attempt_id}",
        base_ref: "main",
        expected_base_revision: "abc123",
        landing_scope: "github_repository:repository-42",
        state: "acquiring",
        cleanup_state: "pending",
        provenance: %{},
        acquired_at: now,
        heartbeat_at: now,
        expires_at: DateTime.add(now, 300, :second)
      }
      |> Map.merge(Map.new(overrides))

    lease = attrs |> WorkspaceLease.create_changeset() |> Repo.insert!()

    lease
    |> WorkspaceLease.update_changeset(%{
      state: "active",
      observed_base_revision: "abc123",
      prepared_at: now
    })
    |> Repo.update!()
  end

  defp claim!(attempt, options) do
    snapshot = %{
      attempt: %{
        attempt_id: attempt.attempt_id,
        work_item_id: attempt.work_item.work_item_id,
        context_bundle_id: attempt.context_bundle.context_bundle_id,
        executor_kind: attempt.executor_kind,
        provider: attempt.provider,
        profile: attempt.profile,
        recipe_version: attempt.recipe_version,
        expected_work_item_version: attempt.expected_work_item_version,
        provenance: %{
          purpose: "github_issue_implementation",
          legacy_routine_id: "routine-pool"
        },
        dispatch: %{legacy_routine_id: "routine-pool"}
      }
    }

    assert {:ok, delivery} =
             WorkProcess.reconcile(
               attempt.work_item.work_item_id,
               attempt.work_item.version,
               snapshot,
               options
             )

    assert delivery.status == :claimed
    delivery
  end

  defp set_active!(attempt) do
    {1, _rows} =
      Repo.update_all(
        from(work_item in WorkItem, where: work_item.id == ^attempt.work_item.id),
        set: [
          state: "active",
          phase: "implementing",
          active_attempt_id: attempt.attempt_id,
          version: 2
        ]
      )

    :ok
  end

  defp worker!(name, overrides \\ []) do
    attrs =
      [
        name: name,
        commands: ["implement"],
        executor_kinds: ["model"],
        providers: ["claude"],
        repositories: :any,
        tools: ~w(Read Glob Grep Edit Write),
        operations: [],
        isolation: ["owned_worktree"],
        features: ~w(cancellation heartbeat structured_output timeout),
        max_concurrency: 1,
        handler: Handler
      ]
      |> Keyword.merge(overrides)

    assert {:ok, worker} = AttemptWorker.new(attrs)
    worker
  end

  defp registry!(workers) do
    assert {:ok, registry} = AttemptWorkerRegistry.new(workers)
    registry
  end

  defp zero_usage(_routine_id), do: %{cost_usd: 0.0, tokens: 0}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp cleanup! do
    Repo.delete_all(WorkspaceLease)
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.delete_all(SpendLedger.Entry)
    Repo.delete_all(WorkEvent)
    Repo.delete_all(WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(Custode.RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(Custode.MissionTarget)
    Repo.delete_all(OperationCall)
    Repo.delete_all(Mission)
    Repo.delete_all(Oban.Job)
  end
end
