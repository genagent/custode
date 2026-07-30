defmodule Custode.RepositoryHealthTest do
  # Repository health projected from deterministic verification evidence
  # (#245): the five states, what makes a verification stale, traversal to
  # the evidence, and determinism under replay.
  use ExUnit.Case, async: false

  alias Custode.{
    Artifact,
    Attempt,
    ContextBundle,
    Mission,
    MissionTarget,
    Repo,
    RepositoryHealth,
    WorkItem
  }

  setup do
    cleanup!()
    on_exit(&cleanup!/0)
    :ok
  end

  describe "classify/1" do
    test "no verification is unknown, not failing" do
      assert {"unknown", :no_verification} = RepositoryHealth.classify(%{classification: nil})
    end

    test "a pass is passing and a test failure is failing" do
      assert {"passing", :verified} = RepositoryHealth.classify(%{classification: "pass"})

      assert {"failing", :verification_failed} =
               RepositoryHealth.classify(%{classification: "test_failure"})
    end

    test "a verdict that could not be rendered is blocked, not failing" do
      # the distinction that earns its keep: nobody knows whether these
      # repositories are healthy, and calling that failing sends someone to
      # debug a suite that never ran
      for classification <- ~w(infrastructure_error timeout policy_refusal cancellation) do
        assert {"blocked", :verdict_unavailable} =
                 RepositoryHealth.classify(%{classification: classification})
      end
    end

    test "a verified revision that is no longer current is stale" do
      assert {"stale", :revision_moved} =
               RepositoryHealth.classify(%{
                 classification: "pass",
                 verified_revision: "abc123",
                 current_revision: "def456"
               })
    end

    test "a revision mismatch outranks a failure" do
      # the failure describes a revision nobody is running any more
      assert {"stale", :revision_moved} =
               RepositoryHealth.classify(%{
                 classification: "test_failure",
                 verified_revision: "abc123",
                 current_revision: "def456"
               })
    end

    test "one missing revision is not a mismatch" do
      facts = %{classification: "pass", verified_revision: "abc123", current_revision: nil}
      assert {"passing", :verified} = RepositoryHealth.classify(facts)

      facts = %{classification: "pass", verified_revision: nil, current_revision: "def456"}
      assert {"passing", :verified} = RepositoryHealth.classify(facts)
    end

    test "a verification older than the window is stale" do
      now = DateTime.utc_now()

      assert {"stale", :verification_aged} =
               RepositoryHealth.classify(%{
                 classification: "pass",
                 verified_at: DateTime.add(now, -48 * 3600, :second),
                 now: now,
                 stale_after: 24 * 3600
               })

      assert {"passing", :verified} =
               RepositoryHealth.classify(%{
                 classification: "pass",
                 verified_at: DateTime.add(now, -2 * 3600, :second),
                 now: now,
                 stale_after: 24 * 3600
               })
    end
  end

  test "health identifies its revision and verification specification, and traverses to evidence" do
    mission = mission!("genagent/custode")
    work_item = work_item!(mission, "work-health-1")

    attempt!(work_item, "attempt-health-1",
      classification: "test_failure",
      revision: "abc123",
      failed: ["mix test"]
    )

    assert %{health: "failing", reason: :verification_failed} = health = get("genagent/custode")

    # the revision and the exact specification that produced the verdict
    assert health.revision == "abc123"
    assert health.recipe == %{"name" => "elixir", "version" => "1", "digest" => "recipe-digest"}
    assert health.classification == "test_failure"
    assert health.failed_commands == ["mix test"]

    # the traversal a human needs to get from a red status to the evidence
    assert health.work_item_id == "work-health-1"
    assert health.attempt_id == "attempt-health-1"
    assert health.artifacts["manifest_artifact_id"] == "manifest-attempt-health-1"
    assert health.contract == "custode.repository_health.v1"
  end

  test "a repository with no verification reads unknown rather than failing" do
    mission!("genagent/never-verified")

    assert %{health: "unknown", reason: :no_verification} =
             health = get("genagent/never-verified")

    assert health.revision == nil
    assert health.attempt_id == nil
  end

  test "a supplied current revision makes a passing verification stale" do
    mission = mission!("genagent/moved-on")
    work_item = work_item!(mission, "work-health-2")
    attempt!(work_item, "attempt-health-2", classification: "pass", revision: "abc123")

    assert %{health: "passing"} = get("genagent/moved-on")

    assert %{health: "stale", reason: :revision_moved} =
             get("genagent/moved-on", revisions: %{"genagent/moved-on" => "def456"})
  end

  test "the newest finished verification decides, and unfinished ones do not" do
    mission = mission!("genagent/newest-wins")
    work_item = work_item!(mission, "work-health-3")
    now = DateTime.utc_now()

    attempt!(work_item, "attempt-old",
      classification: "test_failure",
      finished_at: DateTime.add(now, -3600, :second)
    )

    attempt!(work_item, "attempt-new",
      classification: "pass",
      finished_at: DateTime.add(now, -60, :second)
    )

    # a queued run is not evidence and must not erase a good result
    attempt!(work_item, "attempt-running", classification: "pass", finished_at: nil)

    assert %{health: "passing", attempt_id: "attempt-new"} = get("genagent/newest-wins")
  end

  test "the projection is deterministic and unchanged by replaying evidence" do
    mission = mission!("genagent/deterministic")
    work_item = work_item!(mission, "work-health-4")
    attempt!(work_item, "attempt-health-4", classification: "pass", revision: "abc123")

    now = DateTime.utc_now()
    first = RepositoryHealth.list(now: now)
    second = RepositoryHealth.list(now: now)

    assert first == second

    # re-persisting identical evidence leaves the projection's inputs alone
    assert %{health: "passing"} = get("genagent/deterministic")
  end

  test "verification the projection cannot place is unattributed, not invisible" do
    placed = mission!("genagent/placed")
    work_item!(placed, "work-health-5") |> attempt!("attempt-placed", classification: "pass")

    # a Mission with no github_repository target at all
    orphan = Repo.insert!(mission_row("mission-orphan", "orphan"))
    work_item!(orphan, "work-health-6") |> attempt!("attempt-orphan", classification: "pass")

    projection = RepositoryHealth.list()

    assert Enum.map(projection.items, & &1.repository) == ["genagent/placed"]
    assert projection.unattributed.verifications == 1
    assert %DateTime{} = projection.unattributed.newest_at
  end

  test "a non-verification attempt is not evidence of repository health" do
    mission = mission!("genagent/other-work")
    work_item = work_item!(mission, "work-health-7")

    attempt!(work_item, "attempt-implementation",
      classification: "pass",
      kind: "implementation"
    )

    assert %{health: "unknown"} = get("genagent/other-work")
  end

  defp get(repository, options \\ []), do: RepositoryHealth.get(repository, options)

  defp mission!(repository) do
    id = "mission-" <> String.replace(repository, "/", "-")

    mission = Repo.insert!(mission_row(id, repository))

    Repo.insert!(%MissionTarget{
      mission_id: mission.id,
      kind: "github_repository",
      external_id: repository,
      display_name: repository
    })

    mission
  end

  defp mission_row(id, key) do
    %Mission{
      mission_id: id,
      key: key,
      purpose: "verification evidence fixture",
      lifecycle: "standing",
      status: "active"
    }
  end

  defp work_item!(mission, work_item_id) do
    Repo.insert!(%WorkItem{
      work_item_id: work_item_id,
      mission_id: mission.id,
      kind: "github_issue_to_merge",
      workflow_version: 1,
      objective: "verify the repository",
      acceptance_criteria: %{"checks" => ["mix test"]},
      source: "test",
      external_key: "test:" <> work_item_id,
      state: "active",
      phase: "verification",
      version: 1
    })
  end

  # An Attempt requires a ContextBundle, which requires an Artifact. The chain
  # is the kernel's, not this test's, so it is built rather than stubbed.
  defp context_bundle!(work_item, attempt_id) do
    artifact =
      Repo.insert!(%Artifact{
        artifact_id: "artifact-" <> attempt_id,
        work_item_id: work_item.id,
        mission_id: work_item.mission_id,
        kind: "context_bundle",
        media_type: "application/json",
        location: "memory://" <> attempt_id,
        size_bytes: 0
      })

    Repo.insert!(%ContextBundle{
      context_bundle_id: "bundle-" <> attempt_id,
      work_item_id: work_item.id,
      mission_id: work_item.mission_id,
      artifact_id: artifact.id,
      digest: "digest-" <> attempt_id,
      component_digests: %{}
    })
  end

  defp attempt!(work_item, attempt_id, options) do
    classification = Keyword.fetch!(options, :classification)
    revision = Keyword.get(options, :revision, "abc123")
    finished_at = Keyword.get(options, :finished_at, DateTime.utc_now())

    Repo.insert!(%Attempt{
      attempt_id: attempt_id,
      work_item_id: work_item.id,
      context_bundle_id: context_bundle!(work_item, attempt_id).id,
      executor_kind: "deterministic",
      provider: "custode",
      profile: "verification",
      recipe_version: "1",
      context_digest: "digest-" <> attempt_id,
      expected_work_item_version: 1,
      state: if(classification == "pass", do: "succeeded", else: "failed"),
      finished_at: finished_at,
      usage: %{"commands" => 3, "duration_ms" => 4200},
      error_details: %{"failed_commands" => Keyword.get(options, :failed, [])},
      outcome: %{
        "kind" => Keyword.get(options, :kind, "deterministic_verification"),
        "classification" => classification,
        "recipe" => %{"name" => "elixir", "version" => "1", "digest" => "recipe-digest"},
        "workspace_revision" => %{"revision" => revision},
        "artifacts" => %{"manifest_artifact_id" => "manifest-" <> attempt_id}
      }
    })
  end

  # Every table that references missions, child-first. An incomplete list
  # passes when this file runs alone and fails with a foreign-key error the
  # moment another module leaves a mission-referencing row behind, which is
  # the "passes alone, fails on the third run" shape this repository has been
  # bitten by before.
  defp cleanup! do
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE work_items SET parent_id = NULL")

    for table <- ~w(
          work_events
          work_gates
          attempts
          context_bundles
          artifacts
          workspace_leases
          role_bindings
          legacy_routine_mission_mappings
          work_items
          operation_calls
          mission_targets
          missions
        ) do
      Repo.query!("DELETE FROM #{table}")
    end
  end
end
