defmodule Custode.Gates.CrossProviderReviewTest do
  use ExUnit.Case, async: false

  import Custode.TestHelpers

  alias Custode.Gates.CrossProviderReview
  alias Custode.Gates.Gate
  alias Custode.Gates.Review
  alias Custode.Repo

  @expected_files [
    "checks.json",
    "diff.patch",
    "gate.json",
    "intent.md",
    "manifest.json",
    "review-output-schema.json"
  ]

  setup do
    Repo.delete_all(Gate)
    Repo.delete_all(Review)
    :ok
  end

  test "the opposite provider reviews only named evidence files and attaches typed findings" do
    gate = gate!(:claude, head: "head-one")
    test_pid = self()

    runner = fn provider, args ->
      directory = args["working_dir"]

      send(test_pid, {
        :review_invocation,
        provider,
        args,
        directory,
        Enum.sort(File.ls!(directory))
      })

      {:ok, valid_output()}
    end

    assert :ok = CrossProviderReview.run(gate.id, fetch: fetch("head-one"), runner: runner)

    assert_received {:review_invocation, :codex, args, directory, files}
    assert args["sandbox"] == "read_only"
    assert args["approval_policy"] == "never"
    assert args["search"] == "disabled"
    assert files == @expected_files
    refute File.exists?(directory)

    reviewed = Gate |> Repo.get!(gate.id) |> Repo.preload(:review)
    assert reviewed.review_state == "completed"
    assert reviewed.review.reviewer_provider == "codex"
    assert reviewed.review.author_provider == "claude"
    assert reviewed.review.head_sha == "head-one"
    assert reviewed.review.evidence_digest =~ ~r/^[a-f0-9]{64}$/

    assert [%{"severity" => "WARN", "claim" => "edge case is uncovered"}] =
             Review.findings(reviewed.review)
  end

  test "a Codex-authored gate selects Claude in plan mode" do
    gate = gate!(:codex, head: "head-two")

    runner = fn provider, args ->
      assert provider == :claude
      assert args["permission_mode"] == "plan"
      assert args["hermetic"] == true
      {:ok, valid_output()}
    end

    assert :ok = CrossProviderReview.run(gate.id, fetch: fetch("head-two"), runner: runner)
    assert Repo.get!(Review, Repo.get!(Gate, gate.id).review_id).reviewer_provider == "claude"
  end

  test "an unchanged head reuses its review without another model turn" do
    first = gate!(:claude, head: "same-head")
    assert :ok = CrossProviderReview.run(first.id, fetch: fetch("same-head"), runner: success())

    second = gate!(:claude, head: "same-head")

    assert :ok =
             CrossProviderReview.run(second.id,
               fetch: fetch("same-head"),
               runner: fn _provider, _args -> flunk("unchanged head was reviewed again") end
             )

    first = Repo.get!(Gate, first.id)
    second = Repo.get!(Gate, second.id)
    assert second.review_id == first.review_id
    assert second.review_state == "reused"
    assert Repo.aggregate(Review, :count) == 1
  end

  test "review rounds are capped per pull request" do
    put_env!(:gate_review_max_rounds, 1)
    first = gate!(:claude, head: "round-one")
    assert :ok = CrossProviderReview.run(first.id, fetch: fetch("round-one"), runner: success())

    second = gate!(:claude, head: "round-two")

    assert :ok =
             CrossProviderReview.run(second.id,
               fetch: fetch("round-two"),
               runner: fn _provider, _args -> flunk("round limit was ignored") end
             )

    assert Repo.get!(Gate, second.id).review_state == "round_limit"
    assert Repo.aggregate(Review, :count) == 1
  end

  test "uncited claims fail validation while explicit insufficient evidence may be uncited" do
    uncited = gate!(:claude, head: "uncited")

    output =
      valid_output()
      |> put_in(["findings", Access.at(0), "evidence", "files"], [])

    assert :ok =
             CrossProviderReview.run(uncited.id, fetch: fetch("uncited"), runner: result(output))

    assert Repo.get!(Gate, uncited.id).review_state == "failed"

    insufficient = gate!(:claude, head: "insufficient")

    output = %{
      "summary" => "the supplied evidence cannot establish behavior",
      "findings" => [
        %{
          "severity" => "INSUFFICIENT_EVIDENCE",
          "category" => "coverage",
          "claim" => "runtime behavior is not represented",
          "evidence" => %{"files" => []},
          "proposed_fix" => "supply the missing runtime trace"
        }
      ]
    }

    assert :ok =
             CrossProviderReview.run(insufficient.id,
               fetch: fetch("insufficient"),
               runner: result(output)
             )

    assert Repo.get!(Gate, insufficient.id).review_state == "completed"
  end

  test "eligible gates enqueue one durable review job" do
    gate = gate!(:claude, head: "queued")
    assert :ok = CrossProviderReview.maybe_enqueue(gate)

    assert [%{args: %{"gate_id" => gate_id}}] =
             jobs_for("Custode.GateReviewJob")
             |> Enum.filter(&(&1.args["gate_id"] == gate.id))

    assert gate_id == gate.id
    assert Repo.get!(Gate, gate.id).review_state == "queued"
  end

  defp gate!(provider, opts) do
    id = uid("review-author")
    workspace = tmp_workspace!()

    put_env!(:routines, [
      %{
        id: id,
        provider: provider,
        cron: :manual,
        workspace: workspace,
        prompt: "work",
        repo: "acme/widget"
      }
    ])

    Repo.insert!(%Gate{
      agent_id: id,
      kind: "approval",
      action_id: uid("action"),
      detail: "merge the reviewed change",
      class: "merge",
      repo: "acme/widget",
      pr_number: 42,
      status: "open",
      review_state: opts[:review_state]
    })
  end

  defp fetch(head_sha) do
    fn _gate, _repo ->
      {:ok,
       %{
         pr: %{
           head_sha: head_sha,
           title: "fix the edge case",
           body: "Closes #7"
         },
         intent: %{
           source: "issue",
           number: 7,
           title: "fix the edge case",
           body: "handle empty input"
         },
         checks: %{sha: head_sha, checks: [%{name: "test", conclusion: "success"}]},
         diff: %{
           files: [
             %{path: "lib/widget.ex", patch: "@@ -1 +1 @@\n-old\n+new"}
           ]
         }
       }}
    end
  end

  defp valid_output do
    %{
      "summary" => "one warning",
      "findings" => [
        %{
          "severity" => "WARN",
          "category" => "tests",
          "claim" => "edge case is uncovered",
          "evidence" => %{
            "files" => [%{"path" => "diff.patch", "lines" => "1-3"}]
          },
          "proposed_fix" => "add an empty-input test"
        }
      ]
    }
  end

  defp success, do: result(valid_output())
  defp result(output), do: fn _provider, _args -> {:ok, output} end
end
