defmodule Custode.WorkspaceLeasesTest do
  use ExUnit.Case, async: false

  alias Custode.{
    Artifact,
    Artifacts,
    Attempt,
    Attempts,
    ContextBundle,
    ContextBundles,
    Mission,
    MissionTarget,
    Repo,
    WorkItem,
    WorkspaceLease,
    WorkspaceLeases
  }

  setup do
    cleanup!()
    root = Path.join(System.tmp_dir!(), "custode-leases-#{Ecto.UUID.generate()}")
    repository = Path.join(root, "repository")
    workspaces = Path.join(root, "workspaces")
    artifacts = Path.join(root, "artifacts")
    File.mkdir_p!(repository)
    init_repository!(repository)

    on_exit(fn ->
      cleanup!()
      File.rm_rf!(root)
    end)

    %{root: root, repository: repository, workspaces: workspaces, artifacts: artifacts}
  end

  test "duplicate preparation returns one live lease, worktree, and evidence Artifact", fixture do
    {work_item, attempt} = insert_work_and_attempt!("duplicate", fixture)
    attrs = lease_attrs(work_item, attempt, fixture)

    assert {:ok, {:created, first}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert first.state == "active"
    assert File.dir?(first.workspace_path)

    assert {:ok, {:existing, repeated}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert repeated.lease_id == first.lease_id
    assert Repo.aggregate(WorkspaceLease, :count) == 1
    assert Repo.aggregate(Artifact, :count) == 2

    assert [%{kind: "workspace_preparation"}] =
             work_item.work_item_id
             |> Artifacts.list_for_work_item()
             |> Enum.filter(&(&1.kind == "workspace_preparation"))
  end

  test "incompatible work cannot own one live landing scope", fixture do
    {first_work, first_attempt} = insert_work_and_attempt!("owner-one", fixture)
    {second_work, second_attempt} = insert_work_and_attempt!("owner-two", fixture)

    assert {:ok, {:created, _lease}} =
             WorkspaceLeases.acquire(lease_attrs(first_work, first_attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    attrs =
      second_work
      |> lease_attrs(second_attempt, fixture)
      |> Map.put(:landing_scope, "github_repository:42")

    assert {:error, :workspace_scope_owned} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert Repo.aggregate(WorkspaceLease, :count) == 1
  end

  test "a crash after directory creation is recovered by the same durable lease", fixture do
    {work_item, attempt} = insert_work_and_attempt!("recover", fixture)
    attrs = lease_attrs(work_item, attempt, fixture)

    assert {:error, :simulated_crash} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               after_worktree: fn _lease -> {:error, :simulated_crash} end
             )

    acquiring = WorkspaceLeases.get_for_work_item(work_item.work_item_id)
    assert acquiring.state == "acquiring"
    assert File.dir?(acquiring.workspace_path)

    assert {:ok, {:existing, active}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert active.lease_id == acquiring.lease_id
    assert active.state == "active"
  end

  test "recovery refuses an existing worktree whose branch identity changed", fixture do
    {work_item, attempt} = insert_work_and_attempt!("wrong-branch", fixture)
    attrs = lease_attrs(work_item, attempt, fixture)

    assert {:error, :simulated_crash} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               after_worktree: fn _lease -> {:error, :simulated_crash} end
             )

    acquiring = WorkspaceLeases.get_for_work_item(work_item.work_item_id)
    git!(acquiring.workspace_path, ["switch", "-c", "unexpected"])

    assert {:error, {:workspace_branch_mismatch, "unexpected"}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert WorkspaceLeases.get(acquiring.lease_id).state == "acquiring"
  end

  test "preparation finishes one deterministic Attempt with the next typed transition", fixture do
    {work_item, attempt} = insert_work_and_attempt!("attempt", fixture)
    attrs = lease_attrs(work_item, attempt, fixture)

    assert {:ok, %{attempt: finished, lease: lease}} =
             WorkspaceLeases.prepare_attempt(attempt.attempt_id, attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               duration_ms: 25
             )

    assert finished.state == "succeeded"
    assert finished.usage == %{"duration_ms" => 25}
    assert finished.outcome["workspace_lease"]["lease_id"] == lease.lease_id
    assert finished.outcome["proposal"]["state"] == "waiting"
    assert finished.outcome["proposal"]["phase"] == "compiling_context"

    assert {:ok, %{attempt: repeated, lease: same}} =
             WorkspaceLeases.prepare_attempt(attempt.attempt_id, attrs)

    assert repeated.id == finished.id
    assert same.id == lease.id
  end

  test "a moved base marks the lease stale before further work", fixture do
    {work_item, attempt} = insert_work_and_attempt!("moved-base", fixture)
    attrs = lease_attrs(work_item, attempt, fixture)

    assert {:ok, {:created, _lease}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    File.write!(Path.join(fixture.repository, "next.txt"), "next\n")
    git!(fixture.repository, ["add", "next.txt"])
    git!(fixture.repository, ["commit", "-m", "next"])

    assert {:error, {:stale, "base_revision_changed", stale}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert stale.state == "stale"
    assert stale.cleanup_state == "retained"
    assert File.dir?(stale.workspace_path)
  end

  test "a tracked-dirty repository is refused before a lease is claimed", fixture do
    {work_item, attempt} = insert_work_and_attempt!("dirty", fixture)
    File.write!(Path.join(fixture.repository, "README.md"), "changed\n")

    assert {:error, {:repository_dirty, _details}} =
             WorkspaceLeases.acquire(lease_attrs(work_item, attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert Repo.aggregate(WorkspaceLease, :count) == 0
  end

  test "containment is mandatory and expiry retains the owned directory", fixture do
    {work_item, attempt} = insert_work_and_attempt!("contained", fixture)
    outside = Path.join(fixture.root, "outside")

    assert {:error, :workspace_path_not_contained} =
             work_item
             |> lease_attrs(attempt, fixture)
             |> Map.put(:workspace_path, outside)
             |> WorkspaceLeases.acquire(workspace_root: fixture.workspaces)

    now = ~U[2026-07-29 18:00:00Z]

    assert {:ok, {:created, lease}} =
             WorkspaceLeases.acquire(lease_attrs(work_item, attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               now: now,
               ttl_seconds: 10
             )

    assert {:ok, [expired]} = WorkspaceLeases.reconcile_expired(DateTime.add(now, 11, :second))
    assert expired.state == "stale"
    assert expired.cleanup_state == "retained"
    assert File.dir?(lease.workspace_path)
  end

  test "containment resolves existing symlinks before workspace creation", fixture do
    {work_item, attempt} = insert_work_and_attempt!("symlink", fixture)
    outside = Path.join(fixture.root, "outside")
    escape = Path.join(fixture.workspaces, "escape")
    File.mkdir_p!(outside)
    File.mkdir_p!(fixture.workspaces)
    File.ln_s!(outside, escape)

    attrs =
      work_item
      |> lease_attrs(attempt, fixture)
      |> Map.put(:workspace_path, Path.join(escape, "lease"))

    assert {:error, :workspace_path_not_contained} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    refute File.exists?(Path.join(outside, "lease"))
  end

  test "restart reconciliation stales orphaned terminal WorkItem ownership", fixture do
    {work_item, attempt} = insert_work_and_attempt!("orphaned", fixture)

    assert {:ok, {:created, lease}} =
             WorkspaceLeases.acquire(lease_attrs(work_item, attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts,
               ttl_seconds: 3_600
             )

    assert {:ok, _finished} =
             Attempts.finish(attempt.attempt_id, %{
               state: "succeeded",
               usage: %{},
               outcome: %{kind: "workspace_prepared"}
             })

    work_item
    |> Ecto.Changeset.change(
      state: "completed",
      phase: "landed",
      completed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    assert {:ok, [stale]} = WorkspaceLeases.reconcile()
    assert stale.state == "stale"
    assert stale.cleanup_error == %{code: "work_item_terminal"}
    assert File.dir?(lease.workspace_path)
  end

  test "explicit cleanup is idempotent and refuses a directory without ownership proof",
       fixture do
    {work_item, attempt} = insert_work_and_attempt!("cleanup", fixture)

    assert {:ok, {:created, lease}} =
             WorkspaceLeases.acquire(lease_attrs(work_item, attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert {:ok, released} = WorkspaceLeases.release(lease.lease_id, cleanup: true)
    assert released.state == "released"
    assert released.cleanup_state == "cleaned"
    refute File.exists?(lease.workspace_path)
    assert {:ok, repeated} = WorkspaceLeases.release(lease.lease_id, cleanup: true)
    assert repeated.cleanup_state == "cleaned"

    {other_work, other_attempt} = insert_work_and_attempt!("unproven", fixture)
    attrs = lease_attrs(other_work, other_attempt, fixture)

    assert {:ok, {:created, other}} =
             WorkspaceLeases.acquire(attrs,
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    File.rm_rf!(other.workspace_path)
    File.mkdir_p!(other.workspace_path)
    File.write!(Path.join(other.workspace_path, "user.txt"), "do not delete\n")

    assert {:error, {:cleanup_failed, :workspace_ownership_unproven, failed}} =
             WorkspaceLeases.release(other.lease_id, cleanup: true)

    assert failed.state == "cleanup_failed"
    assert File.exists?(Path.join(other.workspace_path, "user.txt"))
  end

  test "an active workspace lease is an explicit Mission archive obligation", fixture do
    {work_item, attempt} = insert_work_and_attempt!("archive", fixture)

    assert {:ok, {:created, lease}} =
             WorkspaceLeases.acquire(lease_attrs(work_item, attempt, fixture),
               workspace_root: fixture.workspaces,
               artifact_dir: fixture.artifacts
             )

    assert {:ok, _finished} =
             Attempts.finish(attempt.attempt_id, %{
               state: "succeeded",
               usage: %{},
               outcome: %{kind: "workspace_prepared"}
             })

    work_item
    |> Ecto.Changeset.change(
      state: "completed",
      phase: "landed",
      completed_at: DateTime.utc_now()
    )
    |> Repo.update!()

    mission_id = work_item.mission.mission_id

    assert {:error,
            {:active_obligation, %{kind: "workspace_lease", id: lease_id, status: "active"}}} =
             Custode.Missions.archive(mission_id, "archive-lease-test")

    assert lease_id == lease.lease_id
    assert {:ok, _released} = WorkspaceLeases.release(lease.lease_id, cleanup: true)
    assert {:ok, archived} = Custode.Missions.archive(mission_id, "archive-lease-test")
    assert archived.status == "archived"
  end

  defp lease_attrs(work_item, attempt, fixture) do
    %{
      lease_id: "lease-#{work_item.work_item_id}",
      work_item_id: work_item.work_item_id,
      attempt_id: attempt.attempt_id,
      repository_id: "42",
      repository_path: fixture.repository,
      base_ref: "main",
      expected_base_revision: git!(fixture.repository, ["rev-parse", "main"]),
      landing_scope: "github_repository:42"
    }
  end

  defp insert_work_and_attempt!(suffix, fixture) do
    mission =
      %{
        mission_id: "mission-#{suffix}",
        key: "github:repository:42:#{suffix}",
        purpose: "Test #{suffix}",
        lifecycle: "persistent",
        status: "active"
      }
      |> Mission.create_changeset()
      |> Repo.insert!()

    %{
      mission_id: mission.id,
      kind: "github_repository",
      external_id: "42",
      display_name: "genagent/custode"
    }
    |> MissionTarget.changeset()
    |> Repo.insert!()

    work_item =
      %{
        work_item_id: "work-#{suffix}",
        mission_id: mission.id,
        kind: "github_issue_to_merge",
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

    {:ok, {:created, bundle}} =
      ContextBundles.create(work_item.work_item_id, context_body(work_item),
        artifact_dir: Path.join(fixture.artifacts, "contexts")
      )

    {:ok, {:created, attempt}} =
      Attempts.create(%{
        attempt_id: "attempt-#{suffix}",
        work_item_id: work_item.work_item_id,
        context_bundle_id: bundle.context_bundle_id,
        executor_kind: "deterministic",
        provider: "local",
        profile: "workspace-preparation",
        recipe_version: "1",
        expected_work_item_version: work_item.version
      })

    {:ok, running} = Attempts.start(attempt.attempt_id)
    {work_item, running}
  end

  defp context_body(work_item) do
    %{
      "objective" => work_item.objective,
      "acceptance" => work_item.acceptance_criteria,
      "policy" => %{"ref" => work_item.policy_ref},
      "recipe" => %{"name" => "workspace-preparation", "version" => 1},
      "prior_evidence" => [],
      "external_revision" => %{"issue" => 367},
      "workspace_revision" => %{"state" => "unclaimed"}
    }
  end

  defp init_repository!(path) do
    git!(path, ["init", "-b", "main"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Custode Test"])
    File.write!(Path.join(path, "README.md"), "base\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-m", "base"])
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end

  defp cleanup! do
    Repo.delete_all(WorkspaceLease)
    Repo.query!("UPDATE artifacts SET producer_attempt_id = NULL")
    Repo.query!("UPDATE attempts SET caused_by_attempt_id = NULL")
    Repo.delete_all(Attempt)
    Repo.delete_all(ContextBundle)
    Repo.delete_all(Artifact)
    Repo.delete_all(Custode.WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(Custode.RoleBinding)
    Repo.delete_all(Custode.LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Custode.OperationCall)
    Repo.delete_all(Mission)
  end
end
