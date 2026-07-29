defmodule Custode.Repair.PolicyTest do
  use ExUnit.Case, async: true

  alias Custode.{Attempt, WorkItem}
  alias Custode.Repair.{Disposition, Policy}

  test "the disposition contract admits only the five typed paths" do
    assert Disposition.kinds() == ~w(
             infrastructure_retry
             mechanical_repair
             semantic_repair
             human_ask
             terminal_block
           )

    assert {:error, {:unknown_repair_disposition, "guess"}} =
             Disposition.new(base_disposition("guess", nil))

    assert {:error, {:invalid_repair_handler, _details}} =
             Disposition.new(base_disposition("mechanical_repair", "claude"))

    assert {:ok, replay} =
             Disposition.new(base_disposition("mechanical_repair", "git_replay"))

    assert replay.handler == "git_replay"

    assert {:error, {:repair_disposition_field_required, :question}} =
             Disposition.new(base_disposition("human_ask", nil))
  end

  test "deterministic classification covers every disposition" do
    policy = policy!()
    now = DateTime.utc_now()
    work_item = work_item(now)

    cases = [
      {attempt("infrastructure_error"), focused([]), "infrastructure_retry"},
      {attempt("test_failure"), focused([failure("format")]), "mechanical_repair"},
      {attempt("test_failure"), focused([failure("test")]), "semantic_repair"},
      {attempt("human_question", %{"question" => "Which behavior?"}), focused([]), "human_ask"},
      {attempt("policy_refusal"), focused([]), "terminal_block"}
    ]

    Enum.each(cases, fn {failed, failure, expected} ->
      assert {:ok, disposition, snapshot} =
               Policy.evaluate(failed, failure, [failed], work_item, policy, now)

      assert disposition.kind == expected
      assert disposition.failure_artifact_id == "failure-artifact"
      assert snapshot.policy.version == "test-policy"
      assert snapshot.usage.repairs == 0
    end)
  end

  test "prior linked Attempts consume exactly one matching allowance" do
    now = DateTime.utc_now()
    failed = attempt("test_failure")

    prior =
      %Attempt{
        attempt_id: "repair-1",
        provenance: %{
          "purpose" => "github_issue_repair",
          "repair_disposition" => %{"kind" => "semantic_repair"}
        },
        usage: %{}
      }

    policy = policy!(max_repairs: 1)

    assert {:exhausted, disposition, snapshot, limit} =
             Policy.evaluate(
               failed,
               focused([failure("test")]),
               [failed, prior],
               work_item(now),
               policy,
               now
             )

    assert disposition.kind == "semantic_repair"
    assert snapshot.usage.repairs == 1
    assert limit == %{name: "repairs", allowed: 1, observed: 1}
  end

  test "infrastructure retries have a separate allowance from repairs" do
    now = DateTime.utc_now()
    failed = attempt("infrastructure_error")

    prior =
      %Attempt{
        attempt_id: "retry-1",
        provenance: %{
          "purpose" => "github_issue_repair",
          "repair_disposition" => %{"kind" => "infrastructure_retry"}
        },
        usage: %{}
      }

    assert {:exhausted, disposition, snapshot, limit} =
             Policy.evaluate(
               failed,
               focused([]),
               [failed, prior],
               work_item(now),
               policy!(max_infrastructure_retries: 1),
               now
             )

    assert disposition.kind == "infrastructure_retry"
    assert snapshot.usage.infrastructure_retries == 1
    assert snapshot.usage.repairs == 0
    assert limit == %{name: "infrastructure_retries", allowed: 1, observed: 1}
  end

  test "elapsed time and spend are independent typed policy limits" do
    now = DateTime.utc_now()
    failed = attempt("test_failure")

    assert {:exhausted, _disposition, _snapshot, %{name: "elapsed_ms"}} =
             Policy.evaluate(
               failed,
               focused([failure("test")]),
               [failed],
               work_item(DateTime.add(now, -2, :second)),
               policy!(max_elapsed_ms: 1_000),
               now
             )

    costly = %{failed | usage: %{"cost_usd" => 0.5}}

    assert {:exhausted, _disposition, snapshot, limit} =
             Policy.evaluate(
               costly,
               focused([failure("test")]),
               [costly],
               work_item(now),
               policy!(max_spend_usd: 0.5),
               now
             )

    assert snapshot.usage.spend_usd == 0.5
    assert limit == %{name: "spend_usd", allowed: 0.5, observed: 0.5}
  end

  defp policy!(overrides \\ []) do
    attrs =
      %{
        version: "test-policy",
        max_infrastructure_retries: 2,
        max_repairs: 2,
        max_elapsed_ms: 60_000,
        max_spend_usd: 1.0
      }
      |> Map.merge(Map.new(overrides))

    {:ok, policy} = Policy.new(attrs)
    policy
  end

  defp attempt(classification, error_details \\ %{}) do
    %Attempt{
      attempt_id: "failed-attempt",
      error_class: classification,
      error_details: error_details,
      outcome: %{
        "classification" => classification,
        "artifacts" => %{"failure_artifact_id" => "failure-artifact"}
      },
      provenance: %{"purpose" => "github_issue_verification"},
      usage: %{}
    }
  end

  defp work_item(inserted_at), do: %WorkItem{inserted_at: inserted_at}

  defp focused(failures),
    do: %{"artifact_id" => "failure-artifact", "failures" => failures}

  defp failure(category),
    do: %{"category" => category, "status" => "test_failure"}

  defp base_disposition(kind, handler) do
    %{
      kind: kind,
      reason: "reason",
      source_attempt_id: "attempt",
      failure_artifact_id: "artifact",
      handler: handler
    }
  end
end
