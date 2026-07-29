defmodule Custode.GitHubReview.ObservationTest do
  use ExUnit.Case, async: true

  alias Custode.GitHubReview.Observation

  @base %{
    repository: "genagent/custode",
    pull_request_number: 371,
    head_sha: "head-371",
    external_updated_at: "2026-07-29T20:00:00Z"
  }

  test "requires transport-neutral, identifier-rich evidence" do
    assert {:error, {:invalid_github_observation, {:reviews, :identifier_required}}} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "review_feedback",
                 reviews: [%{state: "CHANGES_REQUESTED"}]
               })
             )

    assert {:error, {:invalid_github_observation, :check_identifier_required}} =
             Observation.new(Map.put(@base, :kind, "check_run"))

    assert {:error, {:invalid_github_observation, :comments}} =
             Observation.new(Map.merge(@base, %{kind: "snapshot", comments: [42]}))
  end

  test "normalizes aliases and derives a deterministic identity" do
    attrs =
      Map.merge(@base, %{
        kind: "review",
        delivery_id: "delivery-1",
        reviews: [
          %{
            id: 44,
            state: "CHANGES_REQUESTED",
            submitted_at: "2026-07-29T20:00:00Z"
          }
        ]
      })

    assert {:ok, first} = Observation.new(attrs)
    assert {:ok, second} = Observation.new(%{attrs | delivery_id: "delivery-2"})
    assert first.kind == "review_feedback"
    assert first.external_identity == second.external_identity
    assert first.item_tokens == ["review:44:2026-07-29T20:00:00Z:CHANGES_REQUESTED"]
  end

  test "classifies formatter failures separately from semantic failures" do
    assert {:ok, formatter} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "check_run",
                 checks: [
                   %{
                     id: 51,
                     name: "mix format",
                     status: "completed",
                     conclusion: "failure",
                     completed_at: "2026-07-29T20:00:00Z"
                   }
                 ]
               })
             )

    assert Observation.action(formatter) == %{
             kind: :repair,
             phase: "feedback_ready",
             active_phase: "handling_feedback",
             disposition: "mechanical_repair",
             handler: "elixir_format",
             reason: "all newly failed checks are formatter checks"
           }

    assert {:ok, semantic} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "check_run",
                 checks: [
                   %{
                     id: 52,
                     name: "test",
                     status: "completed",
                     conclusion: "failure",
                     completed_at: "2026-07-29T20:00:00Z"
                   }
                 ]
               })
             )

    assert %{kind: :repair, disposition: "semantic_repair", handler: "claude"} =
             Observation.action(semantic)
  end

  test "classifies pinned conflicts as mechanical replay and clean signals as waiting" do
    assert {:ok, conflict} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "conflict",
                 base_sha: "base-372",
                 conflict: true
               })
             )

    assert %{
             kind: :repair,
             phase: "conflict_ready",
             active_phase: "resolving_conflict",
             disposition: "mechanical_repair",
             handler: "git_replay"
           } = Observation.action(conflict)

    assert {:ok, clean} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "snapshot",
                 conflict: %{status: "clean", base_sha: "base-371"}
               })
             )

    assert Observation.action(clean) == %{kind: :wait, reason: "no actionable review change"}
  end

  test "pins the exact clean head, checks, and latest approving review for merge" do
    assert {:ok, observation} =
             Observation.new(
               Map.merge(@base, %{
                 kind: "snapshot",
                 pull_request: %{
                   state: "open",
                   draft: false,
                   merged: false,
                   mergeable: true,
                   mergeable_state: "clean"
                 },
                 conflict: %{status: "clean", base_sha: "base-371"},
                 reviews: [
                   %{
                     id: 70,
                     author: "reviewer",
                     state: "CHANGES_REQUESTED",
                     commit_id: "head-371",
                     submitted_at: "2026-07-29T20:01:00Z"
                   },
                   %{
                     id: 71,
                     author: "reviewer",
                     state: "APPROVED",
                     commit_id: "head-371",
                     submitted_at: "2026-07-29T20:02:00Z"
                   }
                 ],
                 checks: [
                   %{
                     id: 82,
                     name: "test",
                     status: "completed",
                     conclusion: "success",
                     completed_at: "2026-07-29T20:03:00Z"
                   },
                   %{
                     id: 81,
                     name: "format",
                     status: "completed",
                     conclusion: "skipped",
                     completed_at: "2026-07-29T20:03:00Z"
                   }
                 ]
               })
             )

    assert %{kind: :merge, merge_preconditions: pinned} =
             Observation.merge_action(observation)

    assert pinned["head_sha"] == "head-371"
    assert pinned["base_sha"] == "base-371"
    assert pinned["review_state"]["status"] == "approved"
    assert pinned["review_state"]["id"] == 71
    assert Enum.map(pinned["required_checks"], & &1["name"]) == ["format", "test"]
    assert Enum.map(pinned["approvals"], & &1["id"]) == [71]
  end

  test "a later refusal or a failed check prevents a merge action" do
    common =
      Map.merge(@base, %{
        kind: "snapshot",
        pull_request: %{
          state: "open",
          draft: false,
          merged: false,
          mergeable: true,
          mergeable_state: "clean"
        },
        conflict: %{status: "clean", base_sha: "base-371"},
        reviews: [
          %{
            id: 72,
            state: "APPROVED",
            submitted_at: "2026-07-29T20:01:00Z"
          }
        ]
      })

    assert {:ok, refused} =
             Observation.new(
               Map.put(common, :comments, [
                 %{
                   id: 73,
                   body: "review: needs-human -- inspect the policy boundary",
                   updated_at: "2026-07-29T20:02:00Z"
                 }
               ])
             )

    assert Observation.merge_action(refused) == nil

    assert {:ok, failed} =
             Observation.new(
               Map.put(common, :checks, [
                 %{
                   id: 74,
                   name: "test",
                   status: "completed",
                   conclusion: "failure",
                   completed_at: "2026-07-29T20:03:00Z"
                 }
               ])
             )

    assert Observation.merge_action(failed) == nil
  end
end
