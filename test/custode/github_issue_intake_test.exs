defmodule Custode.GitHubIssueIntakeTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.{
    Attempt,
    GitHubIssueIntake,
    LegacyRoutineMissionMapping,
    Mission,
    MissionTarget,
    OperationCall,
    Repo,
    RoleBinding,
    WorkEvent,
    WorkItem,
    WorkItems
  }

  alias Custode.Operations.Missions, as: MissionOperations

  @repository_id "1307868502"
  @repository "genagent/custode"
  @pilot %{
    repository_id: @repository_id,
    issue_numbers: [368],
    policy_version: "github-issue-intake-v1"
  }

  defmodule RepositoryReader do
    def view_issue(repository, number) do
      send(Application.fetch_env!(:custode, :github_issue_intake_test_pid), {
        :view_issue,
        repository,
        number
      })

      {:ok, Application.fetch_env!(:custode, :github_issue_intake_test_issue)}
    end
  end

  setup do
    Repo.delete_all(WorkEvent)
    Repo.delete_all(Custode.WorkGate)
    Repo.delete_all(Attempt)
    Repo.update_all(WorkItem, set: [parent_id: nil])
    Repo.delete_all(WorkItem)
    Repo.delete_all(RoleBinding)
    Repo.delete_all(OperationCall)
    Repo.delete_all(LegacyRoutineMissionMapping)
    Repo.delete_all(MissionTarget)
    Repo.delete_all(Mission)

    mission = create_mission!()
    %{mission: mission}
  end

  test "one approved poll and a duplicate webhook converge on one eligible WorkItem", %{
    mission: mission
  } do
    insert_mapping!(mission, "custode-dev")
    issue = issue(comments: marker_comments())

    put_env!(:github_issue_intake_test_pid, self())
    put_env!(:github_issue_intake_test_issue, issue)
    put_env!(:repository_reader, RepositoryReader)
    put_env!(:github_issue_intake_pilots, %{"custode-dev" => @pilot})

    routine = %{id: "custode-dev", repo: @repository}

    assert {:ok, [poll]} = GitHubIssueIntake.on_routine_tick(routine)
    assert_receive {:view_issue, @repository, 368}

    assert poll.created
    assert poll.disposition == :eligible
    assert poll.work_item.state == "ready"
    assert poll.work_item.phase == "eligible"

    assert {:ok, webhook} =
             GitHubIssueIntake.reconcile(
               mission,
               @repository_id,
               @repository,
               issue,
               pilot: @pilot,
               delivery_id: "delivery-1"
             )

    refute webhook.created
    refute webhook.observed
    assert webhook.work_item.work_item_id == poll.work_item.work_item_id
    assert webhook.work_item.version == poll.work_item.version
    assert Repo.aggregate(WorkItem, :count) == 1
    assert Repo.aggregate(Attempt, :count) == 0
    assert length(WorkItems.list_events(poll.work_item.work_item_id)) == 3

    snapshot = WorkItems.latest_source_snapshot(poll.work_item.work_item_id)
    assert snapshot["repository_id"] == @repository_id
    assert snapshot["external_updated_at"] == "2026-07-29T17:00:00Z"

    assert snapshot["issue"]["marker"] == %{
             "kind" => "blocked",
             "detail" => "waiting for an operator",
             "comment_id" => 12,
             "author" => "maintainer",
             "updated_at" => "2026-07-29T16:30:00Z"
           }
  end

  test "changed issue content increments the version with a traced typed observation", %{
    mission: mission
  } do
    assert {:ok, initial} = reconcile(mission, issue())

    changed =
      issue(
        title: "Revised intake contract",
        body: "The requirements changed.",
        updated_at: "2026-07-29T18:00:00Z"
      )

    assert {:ok, revised} =
             reconcile(mission, changed,
               correlation_id: "corr-revision",
               causation_id: "cause-revision"
             )

    assert revised.observed
    assert revised.work_item.version == initial.work_item.version + 1

    events = WorkItems.list_events(initial.work_item.work_item_id)
    assert List.last(events).kind == "work_item.observed"
    assert List.last(events).correlation_id == "corr-revision"
    assert List.last(events).causation_id == "cause-revision"
    assert List.last(events).evidence["external_updated_at"] == "2026-07-29T18:00:00Z"
    assert List.last(events).evidence["source_snapshot"]["issue"]["title"] == changed.title
  end

  test "a repository rename preserves source identity and records the new canonical name", %{
    mission: mission
  } do
    assert {:ok, initial} = reconcile(mission, issue(), canonical_name: "genagent/custode")

    assert {:ok, renamed} =
             reconcile(mission, issue(),
               canonical_name: "genagent-renamed/custode",
               causation_id: "repository-rename"
             )

    assert renamed.observed
    assert renamed.work_item.work_item_id == initial.work_item.work_item_id
    assert renamed.work_item.external_key == "github:#{@repository_id}:issue:368"
    assert Repo.aggregate(WorkItem, :count) == 1

    snapshot = WorkItems.latest_source_snapshot(initial.work_item.work_item_id)
    assert snapshot["canonical_name"] == "genagent-renamed/custode"
  end

  test "ignored work remains visible without a provider Attempt and label removal re-evaluates",
       %{
         mission: mission
       } do
    ignored = issue(labels: ["custode:ignore"], updated_at: "2026-07-29T17:10:00Z")

    assert {:ok, withheld} = reconcile(mission, ignored)
    assert withheld.disposition == :ineligible
    assert withheld.work_item.state == "proposed"
    assert withheld.work_item.phase == "ineligible"
    assert Repo.aggregate(Attempt, :count) == 0

    admitted = issue(labels: [], updated_at: "2026-07-29T17:20:00Z")
    assert {:ok, eligible} = reconcile(mission, admitted)
    assert eligible.observed
    assert eligible.work_item.state == "ready"
    assert eligible.work_item.phase == "eligible"
    assert eligible.work_item.version == withheld.work_item.version + 3
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "an ignore label can withdraw a previously eligible item without bypassing transitions", %{
    mission: mission
  } do
    assert {:ok, admitted} = reconcile(mission, issue())

    ignored = issue(labels: ["custode:ignore"], updated_at: "2026-07-29T17:30:00Z")
    assert {:ok, withheld} = reconcile(mission, ignored)
    assert withheld.work_item.state == "proposed"
    assert withheld.work_item.phase == "ineligible"

    events = WorkItems.list_events(admitted.work_item.work_item_id)
    assert Enum.any?(events, &(&1.before_state == "ready" and &1.after_state == "blocked"))
    assert Enum.any?(events, &(&1.before_state == "blocked" and &1.after_state == "proposed"))
  end

  test "a closed source issue receives an explicit terminal disposition", %{mission: mission} do
    assert {:ok, closed} =
             reconcile(
               mission,
               issue(state: "closed", updated_at: "2026-07-29T18:30:00Z")
             )

    assert closed.disposition == :closed
    assert closed.work_item.state == "cancelled"
    assert closed.work_item.outcome["code"] == "github_issue_closed"
    assert closed.work_item.cancelled_at
    assert Repo.aggregate(Attempt, :count) == 0
  end

  test "the stable repository allowlist is checked before any GitHub read", %{mission: mission} do
    insert_mapping!(mission, "custode-dev")
    put_env!(:github_issue_intake_test_pid, self())
    put_env!(:github_issue_intake_test_issue, issue())
    put_env!(:repository_reader, RepositoryReader)

    put_env!(:github_issue_intake_pilots, %{
      "custode-dev" => %{@pilot | repository_id: "not-approved"}
    })

    assert {:error, {:repository_not_approved, "not-approved"}} =
             GitHubIssueIntake.on_routine_tick(%{id: "custode-dev", repo: @repository})

    refute_receive {:view_issue, _, _}
    assert Repo.aggregate(WorkItem, :count) == 0
  end

  defp reconcile(mission, issue, options \\ []) do
    canonical_name = Keyword.get(options, :canonical_name, @repository)

    GitHubIssueIntake.reconcile(
      mission,
      @repository_id,
      canonical_name,
      issue,
      Keyword.put(options, :pilot, @pilot)
    )
  end

  defp issue(overrides \\ []) do
    Map.merge(
      %{
        number: 368,
        title: "Add provider execution",
        body: "Implement the bounded provider execution slice.",
        state: "open",
        labels: ["enhancement"],
        updated_at: "2026-07-29T17:00:00Z",
        url: "https://github.com/genagent/custode/issues/368",
        comments: []
      },
      Map.new(overrides)
    )
  end

  defp marker_comments do
    [
      %{
        id: 11,
        author: "maintainer",
        body: "ready: bounded plan",
        updated_at: "2026-07-29T16:00:00Z"
      },
      %{
        id: 12,
        author: "maintainer",
        body: "blocked: waiting for an operator",
        updated_at: "2026-07-29T16:30:00Z"
      }
    ]
  end

  defp create_mission! do
    attrs = %{
      key: "github:repository:#{@repository_id}",
      purpose: "Operate #{@repository}",
      lifecycle: "persistent",
      targets: [
        %{
          kind: "github_repository",
          external_id: @repository_id,
          display_name: @repository
        }
      ]
    }

    {:ok, response} =
      MissionOperations.Create.dispatch(
        attrs,
        actor: %{kind: :operator, id: "human"},
        transport: :worker,
        idempotency_key: "intake-test-mission"
      )

    Custode.Missions.get(response.result.mission.mission_id)
  end

  defp insert_mapping!(mission, routine_id) do
    snapshot = %{
      source: %{
        kind: "legacy_routine_repository",
        repository_id: @repository_id,
        canonical_name: @repository
      }
    }

    %{
      mapping_id: Ecto.UUID.generate(),
      legacy_routine_id: routine_id,
      mission_id: mission.id,
      strategy: "repository",
      mapping_identity: "github_repository:#{@repository_id}",
      status: "active",
      source_snapshot: snapshot,
      last_observed_snapshot: snapshot,
      last_observed_fingerprint: "intake-test-fingerprint"
    }
    |> LegacyRoutineMissionMapping.create_changeset()
    |> Repo.insert!()
  end
end
