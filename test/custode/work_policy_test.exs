defmodule Custode.WorkPolicyTest do
  use ExUnit.Case, async: true

  alias Custode.{Mission, WorkItem, WorkPolicy}
  alias Custode.WorkPolicy.Definition

  test "compatibility policy gives auto, ask, and ineligible stable semantics" do
    work_item = work_item()
    routine = routine()

    assert {:ok, auto} = WorkPolicy.compatibility(routine, work_item)
    assert auto.posture == :auto
    refute auto.controls.gates.required

    assert {:ok, ask} =
             WorkPolicy.compatibility(routine, work_item,
               risk: :external_write,
               repository: "genagent/custode"
             )

    assert ask.posture == :ask
    assert ask.controls.gates.required

    assert {:ok, ineligible} =
             WorkPolicy.intake(%{work_item | phase: "ineligible"}, :ineligible)

    assert ineligible.posture == :ineligible
    refute ineligible.controls.gates.required
  end

  test "the same inputs and version produce the same exact decision" do
    options = [
      provider: "codex",
      selection: %{"model" => "gpt-5.6-codex", "effort" => "high"},
      repository: "genagent/custode"
    ]

    assert {:ok, first} = WorkPolicy.compatibility(routine(), work_item(), options)
    assert {:ok, second} = WorkPolicy.compatibility(routine(), work_item(), options)

    assert WorkPolicy.render(first) == WorkPolicy.render(second)
    assert first.fingerprint == second.fingerprint
    assert first.version == "policy:test:v1"
  end

  test "quality and budget controls are separate and all effective limits are pinned" do
    assert {:ok, decision} =
             WorkPolicy.compatibility(routine(), work_item(),
               provider: "codex",
               selection: %{"model" => "gpt-5.6-codex", "effort" => "high"},
               max_context_tokens: 120_000,
               max_concurrency: 2
             )

    assert decision.controls.quality.verification.required
    assert decision.controls.quality.review.depth == "existing"

    assert decision.controls.budget == %{
             daily_budget_tokens: 50_000,
             daily_budget_usd: 4.0,
             max_spend_usd: 1.5
           }

    assert decision.controls.execution == %{
             limits: %{
               max_context_tokens: 120_000,
               max_turns: 24,
               timeout_ms: 600_000
             },
             max_concurrency: 2,
             provider: "codex",
             selection: %{effort: "high", model: "gpt-5.6-codex"}
           }

    assert decision.controls.retry.max_infrastructure_retries == 2
    assert decision.controls.retry.max_repairs == 2
    assert decision.controls.retry.max_elapsed_ms == 3_600_000
  end

  test "selection is order-independent and rejects duplicate or ambiguous rules" do
    broad = definition!("broad", %{work_kind: "github_issue_to_merge"}, :auto)

    specific =
      definition!(
        "specific",
        %{work_kind: "github_issue_to_merge", risk: :external_write},
        :ask
      )

    inputs = %{
      policy_version: "policy:test:v1",
      work_kind: "github_issue_to_merge",
      risk: :external_write
    }

    for rules <- [[broad, specific], [specific, broad]] do
      assert {:ok, registry} = WorkPolicy.new(rules)
      assert {:ok, decision} = WorkPolicy.select(registry, inputs)
      assert decision.name == "specific"
      assert decision.posture == :ask
    end

    assert {:error, {:duplicate_work_policy, _identity}} =
             WorkPolicy.new([broad, broad])

    peer =
      definition!(
        "peer",
        %{work_kind: "github_issue_to_merge", repository: "genagent/custode"},
        :auto
      )

    ambiguous_inputs = Map.put(inputs, :repository, "genagent/custode")
    assert {:ok, registry} = WorkPolicy.new([specific, peer])

    assert {:error, {:ambiguous_work_policy, matches}} =
             WorkPolicy.select(registry, ambiguous_inputs)

    assert Enum.map(matches, & &1.name) == ["peer", "specific"]
  end

  test "retry and repair allowances must be explicitly bounded" do
    attrs = definition_attrs("invalid", %{work_kind: "github_issue_to_merge"}, :auto)
    attrs = put_in(attrs, [:retry, :max_repairs], nil)

    assert {:error, {:invalid_work_policy_limit, :max_repairs, nil}} =
             Definition.new(attrs)
  end

  defp definition!(name, selectors, posture) do
    {:ok, definition} = Definition.new(definition_attrs(name, selectors, posture))
    definition
  end

  defp definition_attrs(name, selectors, posture) do
    %{
      name: name,
      version: "policy:test:v1",
      selectors: selectors,
      posture: posture,
      quality: %{verification: %{required: true}},
      budget: %{max_spend_usd: 1.0},
      execution: %{limits: %{max_turns: 10}, max_concurrency: 1},
      retry: %{max_infrastructure_retries: 1, max_repairs: 1},
      gates: %{required: posture == :ask},
      reason: "test policy"
    }
  end

  defp routine do
    %{
      max_turns: 24,
      max_budget_usd: 1.5,
      daily_budget_usd: 4.0,
      daily_budget_tokens: 50_000,
      timeout_ms: 600_000
    }
  end

  defp work_item do
    %WorkItem{
      work_item_id: "work-policy-test",
      kind: "github_issue_to_merge",
      workflow_version: 1,
      phase: "implementation_ready",
      policy_ref: "policy:test:v1",
      mission: %Mission{
        mission_id: "mission-policy-test",
        policy_ref: "policy:test:v1"
      }
    }
  end
end
