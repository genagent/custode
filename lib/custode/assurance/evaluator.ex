defmodule Custode.Assurance.Evaluator do
  @moduledoc "Pure predicate evaluation of recorder-issued receipts; never effect admission."

  @bindings ~w(case_revision artifact_revision policy_digest generation)

  def evaluate(attempt, evidence, current_policy_digest) do
    results = Enum.map(attempt["policy"]["predicates"], &predicate(&1, attempt, evidence))
    judge = judge(attempt, evidence)
    results = results ++ [judge]

    results =
      if current_policy_digest == attempt["policy_digest"],
        do: results,
        else:
          Enum.map(
            results,
            &Map.merge(&1, %{"state" => "missing", "eligible_evidence_ids" => []})
          )

    missing = for result <- results, result["state"] == "missing", do: result["name"]
    contradictions = for result <- results, result["state"] == "contradictory", do: result["name"]
    satisfied = for result <- results, result["state"] == "satisfied", do: result["name"]

    missing =
      if current_policy_digest == attempt["policy_digest"],
        do: missing,
        else: ["current_policy" | missing]

    %{
      "status" => status(missing, contradictions),
      "satisfied" => satisfied,
      "missing" => missing,
      "contradictory" => contradictions,
      "predicates" => results,
      "evidence_ids" => Enum.map(evidence, & &1["id"]),
      "binding" => Map.take(attempt, @bindings),
      "effect_authority" => "none"
    }
  end

  defp predicate(policy, attempt, evidence) do
    candidates = Enum.filter(evidence, &(&1["predicate"] == policy["name"]))
    eligible = Enum.filter(candidates, &eligible?(&1, policy, attempt))

    result(policy["name"], candidates, eligible)
    |> Map.put(
      "excluded_evidence",
      for(
        receipt <- candidates,
        receipt not in eligible,
        do: %{"id" => receipt["id"], "reasons" => exclusions(receipt, policy, attempt)}
      )
    )
  end

  defp eligible?(receipt, policy, attempt), do: exclusions(receipt, policy, attempt) == []

  defp exclusions(receipt, policy, attempt) do
    checks = [
      {exact?(receipt, attempt), "exact_case_artifact_policy_generation"},
      {receipt["issuer"] == "custode.assurance.v1", "recorder_issuer"},
      {receipt["kind"] in policy["sources"], "configured_source"},
      {receipt["claim_class"] in policy["classes"], "required_claim_class"},
      {receipt["missing_bindings"] == [], "source_bindings"},
      {independent?(policy, receipt, attempt), "independent_actor_provider_run_revision"}
    ]

    for {false, reason} <- checks, do: reason
  end

  defp independent?(%{"independent" => true}, receipt, attempt) do
    producer = attempt["producer"]
    verifier = receipt["execution"]

    identity?(producer) and identity?(verifier) and
      verifier["actor"] != producer["actor"] and verifier["provider"] != producer["provider"] and
      verifier["run_id"] != producer["run_id"]
  end

  defp independent?(_policy, _receipt, _attempt), do: true

  defp identity?(execution) when is_map(execution),
    do: Enum.all?(~w(actor provider run_id revision), &text?(execution[&1]))

  defp identity?(_execution), do: false

  defp judge(attempt, evidence) do
    candidates = Enum.filter(evidence, &(&1["kind"] == "judge"))

    eligible =
      Enum.filter(candidates, fn receipt ->
        exact?(receipt, attempt) and receipt["issuer"] == "custode.assurance.v1" and
          receipt["claim_class"] == "designated_judge" and receipt["actor"] == attempt["judge_id"]
      end)

    result("designated_judge", candidates, eligible)
  end

  defp exact?(receipt, attempt),
    do: Enum.all?(@bindings, &(get_in(receipt, ["binding", &1]) == attempt[&1]))

  defp result(name, candidates, eligible) do
    state =
      cond do
        Enum.any?(eligible, &(&1["outcome"] == "failed")) -> "contradictory"
        Enum.any?(eligible, &(&1["outcome"] == "passed")) -> "satisfied"
        true -> "missing"
      end

    %{
      "name" => name,
      "state" => state,
      "eligible_evidence_ids" => Enum.map(eligible, & &1["id"]),
      "considered_evidence_ids" => Enum.map(candidates, & &1["id"])
    }
  end

  defp status(_missing, [_ | _]), do: "rejected"
  defp status([_ | _], []), do: "escalated"
  defp status([], []), do: "accepted"
  defp text?(value), do: is_binary(value) and value != ""
end
