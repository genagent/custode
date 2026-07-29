defmodule Custode.RoleBindingsTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{
    LegacyRoleBindingProjection,
    LegacyRoutineMissionMapping,
    Mission,
    Missions,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding,
    RoleBindings,
    RoleTemplates
  }

  alias Custode.Operations.RoleBindings, as: RoleBindingOperations

  setup do
    Repo.delete_all(Custode.WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.update_all(Custode.WorkItem, set: [parent_id: nil])
    Repo.delete_all(Custode.WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(OperationCall)
    Repo.delete_all(Mission)
    :ok
  end

  test "RoleTemplates deterministically project roles, profiles, prompt assets, and current grants" do
    first = RoleTemplates.fetch!("profile:backlog_worker")
    second = RoleTemplates.fetch!("profile:backlog_worker")

    assert first.version == second.version
    assert first.role == "backlog_worker"
    assert first.operation_grants == ["worker"]
    assert first.executor_defaults["model"] == "sonnet"
    assert first.executor_defaults["max_turns"] == 75
    assert first.recipe == %{"kind" => "legacy_routine_profile", "name" => "backlog_worker"}

    assert [%{"module" => "Custode.Routine.Prompts", "role" => "backlog_worker"} = prompt] =
             first.prompt_assets

    assert prompt["function"] == "for_role/2"
    assert "mcp__custode__repo_view_issue" in first.transport_allowlists["mcp"]
    refute "mcp__custode__pause_agent" in first.transport_allowlists["mcp"]

    unknown = RoleTemplates.for_routine(%{role: :not_registered})
    assert unknown.key == "role:assistant"
    assert unknown.operation_grants == ["worker"]
    refute "mcp__custode__pause_agent" in unknown.transport_allowlists["mcp"]
  end

  test "a Mission-backed legacy routine projects to one stable read-only binding" do
    mission = mission!("github:repository:42")

    routine =
      routine_fixture!(tmp_workspace!(), %{
        id: "widget-worker",
        profile: :backlog_worker,
        role: :backlog_worker,
        mcp: true,
        max_turns: 41
      })

    mapping = mapping(routine.id, mission, "repository")

    assert {:ok, [first]} =
             LegacyRoleBindingProjection.project_all(
               routines: [routine],
               mission_mappings: [mapping]
             )

    assert first.result.binding.authority_source == "legacy_routine"
    assert first.result.binding.template_key == "profile:backlog_worker"
    assert first.result.binding.scoped_overrides.max_turns == 41
    binding_id = first.result.binding.binding_id

    assert {:ok, [replay]} =
             LegacyRoleBindingProjection.project_all(
               routines: [routine],
               mission_mappings: [mapping]
             )

    assert replay.call_id == first.call_id
    assert replay.result.binding.binding_id == binding_id
    assert Repo.aggregate(RoleBinding, :count) == 1

    assert {:error, {:handler_failed, {:read_only_legacy_binding, ^binding_id}}} =
             RoleBindingOperations.Update.dispatch(
               binding_id,
               %{scoped_overrides: %{max_turns: 99}},
               invocation("legacy-write-refused")
             )

    assert RoleBindings.get(binding_id).scoped_overrides["max_turns"] == 41
  end

  test "legacy config changes update the projection without changing binding identity" do
    mission = mission!("github:repository:42")

    first =
      routine_fixture!(tmp_workspace!(), %{
        id: "widget-steward",
        profile: :steward,
        max_turns: 20
      })

    mapping = mapping(first.id, mission, "repository")
    assert {:ok, [_response]} = project(first, mapping)
    original = RoleBindings.get_by_legacy_routine(first.id)

    changed = %{first | max_turns: 22}
    assert {:ok, [_response]} = project(changed, mapping)
    updated = RoleBindings.get_by_legacy_routine(first.id)

    assert updated.binding_id == original.binding_id
    assert updated.scoped_overrides["max_turns"] == 22
    assert updated.provenance["authority"] == "legacy_routine"
    assert Repo.aggregate(RoleBinding, :count) == 1
    assert Repo.aggregate(OperationCall, :count) == 2
  end

  test "database-native reviewer binding exists without a routine or provider process" do
    mission = mission!("github:repository:42")

    assert {:ok, response} =
             RoleBindingOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 key: "reviewer",
                 template_key: "role:reviewer",
                 scoped_overrides: %{max_turns: 12}
               },
               invocation("bind-reviewer")
             )

    binding = RoleBindings.get(response.result.binding.binding_id)
    assert binding.authority_source == "database"
    assert binding.legacy_routine_id == nil
    assert binding.template_key == "role:reviewer"
    assert binding.scoped_overrides == %{"max_turns" => 12}

    reviewer_routine = routine_fixture!(tmp_workspace!(), %{id: "reviewer", role: :reviewer})
    global_mapping = mapping("reviewer", nil, "repository_attempts")

    assert {:ok, [%{status: :template_only, strategy: "repository_attempts"}]} =
             LegacyRoleBindingProjection.project_all(
               routines: [reviewer_routine],
               mission_mappings: [global_mapping]
             )

    assert RoleBindings.get_by_legacy_routine("reviewer") == nil
    assert RoleBindings.list_for_mission(mission.mission_id) == [binding]
  end

  test "database-native lifecycle is mutable but unknown actors retain least privilege" do
    mission = mission!("topic:ops")

    assert {:error, {:denied, :operator_required}} =
             RoleBindingOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 key: "assistant",
                 template_key: "role:assistant"
               },
               actor: %{kind: :routine, id: "unknown-role"},
               transport: :worker,
               idempotency_key: "unknown-create"
             )

    assert Repo.aggregate(RoleBinding, :count) == 0

    assert %OperationCall{status: "denied"} =
             Repo.get_by!(OperationCall, idempotency_key: "unknown-create")

    assert {:ok, created} =
             RoleBindingOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 key: "assistant",
                 template_key: "role:assistant"
               },
               invocation("assistant-create")
             )

    binding_id = created.result.binding.binding_id

    assert {:ok, retired} =
             RoleBindingOperations.Update.dispatch(
               binding_id,
               %{lifecycle: "retired"},
               invocation("assistant-retire")
             )

    assert retired.result.binding.lifecycle == "retired"
    assert retired.result.binding.retired_at
  end

  test "dry runs preview a database-native binding without creating it" do
    mission = mission!("topic:preview")

    assert {:ok, response} =
             RoleBindingOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 key: "reviewer",
                 template_key: "role:reviewer"
               },
               Keyword.put(invocation("reviewer-preview"), :dry_run, true)
             )

    assert response.status == :dry_run
    assert response.effect_preview.effect == "create_role_binding"
    assert Repo.aggregate(RoleBinding, :count) == 0

    assert %OperationCall{status: "succeeded", dry_run: true} =
             Repo.get_by!(OperationCall, idempotency_key: "reviewer-preview")
  end

  test "future Attempt provenance is a value pinned to the selected template version" do
    mission = mission!("topic:versioned")

    profiles = %{
      versioned: %{
        role: :reviewer,
        model: "sonnet",
        max_turns: 10
      }
    }

    put_env!(:profiles, profiles)

    assert {:ok, created} =
             RoleBindingOperations.Create.dispatch(
               %{
                 mission_id: mission.mission_id,
                 key: "versioned",
                 template_key: "profile:versioned"
               },
               invocation("versioned-create")
             )

    binding = RoleBindings.get(created.result.binding.binding_id)
    first_provenance = RoleBindings.attempt_provenance(binding)

    Application.put_env(:custode, :profiles, put_in(profiles, [:versioned, :max_turns], 20))

    assert {:ok, updated} =
             RoleBindingOperations.Update.dispatch(
               binding.binding_id,
               %{template_key: "profile:versioned"},
               invocation("versioned-update")
             )

    second = RoleBindings.get(updated.result.binding.binding_id)
    second_provenance = RoleBindings.attempt_provenance(second)

    refute first_provenance["role_template_version"] ==
             second_provenance["role_template_version"]

    assert first_provenance["role_template_version"] == binding.template_version
    assert first_provenance["role_binding_id"] == second_provenance["role_binding_id"]
  end

  test "stale template versions are refused before a legacy binding mutation" do
    mission = mission!("topic:stale")
    routine = routine_fixture!(tmp_workspace!(), %{id: "stale-worker", role: :assistant})
    observation = LegacyRoleBindingProjection.observation(routine, mission.mission_id)
    stale = Map.put(observation, "template_version", "sha256:stale")

    assert {:error,
            {:handler_failed,
             {:stale_role_template, %{expected: expected, observed: "sha256:stale"}}}} =
             RoleBindingOperations.ProjectLegacyRoutine.dispatch(stale,
               actor: %{kind: :system, id: "test"},
               transport: :system
             )

    assert String.starts_with?(expected, "sha256:")
    assert Repo.aggregate(RoleBinding, :count) == 0
  end

  defp project(routine, mapping) do
    LegacyRoleBindingProjection.project_all(
      routines: [routine],
      mission_mappings: [mapping]
    )
  end

  defp mission!(key) do
    {:ok, {:created, mission}} =
      Missions.create(%{
        key: key,
        purpose: "Mission #{key}",
        lifecycle: "persistent",
        targets: [%{kind: "topic", external_id: key, display_name: key}]
      })

    mission
  end

  defp mapping(legacy_routine_id, mission, strategy) do
    %LegacyRoutineMissionMapping{
      legacy_routine_id: legacy_routine_id,
      mission: mission,
      mission_id: mission && mission.id,
      strategy: strategy
    }
  end

  defp invocation(key) do
    [
      actor: %{kind: :operator, id: "human"},
      transport: :worker,
      idempotency_key: key
    ]
  end
end
