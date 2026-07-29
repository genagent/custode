defmodule Custode.LegacyMissionProjectionTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{
    LegacyMissionProjection,
    LegacyRoutineMissionMapping,
    Mission,
    Missions,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding
  }

  alias Custode.Operations.Missions.ProjectLegacyRoutine

  defmodule RepositoryIdentity do
    @behaviour Custode.GitHub.RepositoryIdentityBehaviour

    @impl true
    def resolve(repo) do
      case Application.fetch_env!(:custode, :test_repository_identities) |> Map.fetch!(repo) do
        {:error, _reason} = error -> error
        identity -> {:ok, identity}
      end
    end
  end

  setup do
    Repo.delete_all(RoleBinding)
    Repo.delete_all(OperationCall)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Mission)
    :ok
  end

  test "repository routines converge on one stable Mission and exact reruns replay" do
    identities = %{
      "acme/widget" => %{id: "42", name_with_owner: "acme/widget"}
    }

    put_env!(:test_repository_identities, identities)

    routines = [
      %{id: "widget-worker", repo: "acme/widget", cron: "@daily"},
      %{id: "widget-steward", repo: "acme/widget", cron: "@weekly"}
    ]

    assert {:ok, first} = project(routines)
    assert length(first) == 2

    assert [mission] = Missions.list()
    assert [%{external_id: "42", display_name: "acme/widget"}] = mission.targets

    assert [steward, worker] =
             LegacyMissionProjection.list()
             |> Enum.sort_by(& &1.legacy_routine_id)

    assert steward.mission_id == worker.mission_id

    changed_schedule =
      Enum.map(routines, fn routine -> Map.put(routine, :cron, "*/5 * * * *") end)

    assert {:ok, replayed} = project(changed_schedule)
    assert Enum.all?(replayed, & &1.replayed)
    assert Repo.aggregate(OperationCall, :count) == 2
    assert Repo.aggregate(LegacyRoutineMissionMapping, :count) == 2
    assert Repo.aggregate(Mission, :count) == 1

    calls = Repo.all(OperationCall)
    assert calls |> Enum.map(& &1.correlation_id) |> Enum.uniq() |> length() == 1

    assert Enum.all?(calls, fn call ->
             Enum.any?(call.effects["items"], &(&1["type"] == "legacy_routine_mapped"))
           end)
  end

  test "repository rename updates only the mutable projection at the same stable ID" do
    put_env!(:test_repository_identities, %{
      "acme/widget" => %{id: "42", name_with_owner: "acme/widget"}
    })

    assert {:ok, _responses} = project([%{id: "worker", repo: "acme/widget"}])
    original = LegacyMissionProjection.get_by_routine("worker")
    mission_id = original.mission.mission_id

    Application.put_env(:custode, :test_repository_identities, %{
      "widgets/widget" => %{id: "42", name_with_owner: "widgets/widget"}
    })

    assert {:ok, [response]} = project([%{id: "worker", repo: "widgets/widget"}])
    assert response.result.mapping.status == "active"
    assert effect_types(response) == ["legacy_repository_projection_updated"]

    mapping = LegacyMissionProjection.get_by_routine("worker")
    assert mapping.mission.mission_id == mission_id
    assert mapping.source_snapshot["source"]["configured_name"] == "acme/widget"
    assert mapping.last_observed_snapshot["source"]["configured_name"] == "widgets/widget"
    assert [%{external_id: "42", display_name: "widgets/widget"}] = mapping.mission.targets
    assert Repo.aggregate(Mission, :count) == 1
    assert Repo.aggregate(OperationCall, :count) == 2
  end

  test "changed repository identity records a named exception without moving history" do
    put_env!(:test_repository_identities, %{
      "acme/widget" => %{id: "42", name_with_owner: "acme/widget"}
    })

    assert {:ok, _responses} = project([%{id: "worker", repo: "acme/widget"}])
    original = LegacyMissionProjection.get_by_routine("worker")

    Application.put_env(:custode, :test_repository_identities, %{
      "other/widget" => %{id: "99", name_with_owner: "other/widget"}
    })

    assert {:ok, [response]} = project([%{id: "worker", repo: "other/widget"}])
    assert effect_types(response) == ["legacy_routine_mapping_drifted"]

    mapping = LegacyMissionProjection.get_by_routine("worker")
    assert mapping.status == "exception"
    assert mapping.mission.mission_id == original.mission.mission_id
    assert mapping.mapping_identity == "github_repository:42"

    assert mapping.exception == %{
             "type" => "mapping_drift",
             "expected" => %{
               "strategy" => "repository",
               "mapping_identity" => "github_repository:42"
             },
             "observed" => %{
               "strategy" => "repository",
               "mapping_identity" => "github_repository:99"
             }
           }

    assert [%{external_id: "42", display_name: "acme/widget"}] = mapping.mission.targets
    assert Missions.get_by_key("github:repository:99") == nil
    assert Repo.aggregate(Mission, :count) == 1
  end

  test "roster rename creates new provenance while removal preserves the old mapping" do
    put_env!(:test_repository_identities, %{
      "acme/widget" => %{id: "42", name_with_owner: "acme/widget"}
    })

    assert {:ok, _responses} = project([%{id: "old-worker", repo: "acme/widget"}])
    old = LegacyMissionProjection.get_by_routine("old-worker")

    assert {:ok, _responses} = project([%{id: "new-worker", repo: "acme/widget"}])
    new = LegacyMissionProjection.get_by_routine("new-worker")

    assert old.mapping_id != new.mapping_id
    assert old.mission.mission_id == new.mission.mission_id

    assert {:ok, []} = project([])
    assert LegacyMissionProjection.get_by_routine("old-worker").mapping_id == old.mapping_id
    assert LegacyMissionProjection.get_by_routine("new-worker").mapping_id == new.mapping_id
  end

  test "approved non-repository seeds remain explicit and separate" do
    routines =
      for id <- ~w(custode quakes stars contributors reviewer consistency), do: %{id: id}

    assert {:ok, responses} =
             LegacyMissionProjection.project_all(
               routines: routines,
               seeds: Application.fetch_env!(:custode, :legacy_mission_mappings),
               repository_identity: RepositoryIdentity
             )

    assert length(responses) == 6
    assert Repo.aggregate(LegacyRoutineMissionMapping, :count) == 6
    assert Repo.aggregate(Mission, :count) == 4

    stars = LegacyMissionProjection.get_by_routine("stars")
    contributors = LegacyMissionProjection.get_by_routine("contributors")
    reviewer = LegacyMissionProjection.get_by_routine("reviewer")
    consistency = LegacyMissionProjection.get_by_routine("consistency")

    assert stars.mission.mission_id != contributors.mission.mission_id
    assert reviewer.strategy == "repository_attempts"
    assert reviewer.mission == nil
    assert consistency.strategy == "ephemeral_per_investigation"
    assert consistency.mission == nil

    assert {:error,
            %{
              failures: [
                %{
                  legacy_routine_id: "unseeded-global",
                  reason: {:explicit_mapping_required, "unseeded-global"}
                }
              ]
            }} =
             LegacyMissionProjection.project_all(
               routines: [%{id: "unseeded-global"}],
               seeds: %{},
               repository_identity: RepositoryIdentity
             )

    assert LegacyMissionProjection.get_by_routine("unseeded-global") == nil
  end

  test "projection operation retains operator authorization" do
    observation = %{
      legacy_routine_id: "worker",
      strategy: "repository_attempts",
      mapping_identity: "strategy:repository_attempts",
      source: %{kind: "explicit_seed", seed_id: "worker"}
    }

    assert {:error, {:denied, :operator_required}} =
             ProjectLegacyRoutine.dispatch(observation,
               actor: %{kind: :routine, id: "unknown-specialist"},
               transport: :worker
             )

    assert LegacyMissionProjection.get_by_routine("worker") == nil
    assert %OperationCall{status: "denied"} = Repo.one!(OperationCall)
  end

  test "nested repository identity fields are validated before mutation" do
    observation = %{
      legacy_routine_id: "worker",
      strategy: "repository",
      mapping_identity: "github_repository:42",
      source: %{
        kind: "legacy_routine_repository",
        repository_id: "42",
        canonical_name: "acme/widget"
      },
      mission: %{
        key: "github:repository:99",
        purpose: "Wrong stable identity",
        lifecycle: "persistent",
        targets: [
          %{kind: "github_repository", external_id: "99", display_name: "acme/widget"}
        ]
      }
    }

    assert {:error,
            {:handler_failed,
             {:invalid_projection, %{legacy_routine_id: "worker", strategy: "repository"}}}} =
             ProjectLegacyRoutine.dispatch(observation,
               actor: %{kind: :operator, id: "human"},
               transport: :worker
             )

    assert LegacyMissionProjection.get_by_routine("worker") == nil
    assert Repo.aggregate(Mission, :count) == 0
  end

  defp project(routines) do
    LegacyMissionProjection.project_all(
      routines: routines,
      seeds: %{},
      repository_identity: RepositoryIdentity
    )
  end

  defp effect_types(response), do: Enum.map(response.effects, & &1.type)
end
