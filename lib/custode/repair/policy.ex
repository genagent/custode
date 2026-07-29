defmodule Custode.Repair.Policy do
  @moduledoc """
  Declarative limits and deterministic failure classification for the first
  repository repair loop.
  """

  alias Custode.{Attempt, WorkItem}
  alias Custode.Repair.Disposition

  @version "github_issue_repair_v1"
  @repair_kinds ~w(mechanical_repair semantic_repair)
  @infrastructure_classes ~w(infrastructure_error retryable_infrastructure timeout)

  @enforce_keys [
    :version,
    :max_infrastructure_retries,
    :max_repairs,
    :max_elapsed_ms,
    :max_spend_usd
  ]
  defstruct [
    :version,
    :max_infrastructure_retries,
    :max_repairs,
    :max_elapsed_ms,
    :max_spend_usd
  ]

  @type t :: %__MODULE__{
          version: String.t(),
          max_infrastructure_retries: non_neg_integer(),
          max_repairs: non_neg_integer(),
          max_elapsed_ms: pos_integer(),
          max_spend_usd: number()
        }

  @spec default(map()) :: t()
  def default(routine) do
    {:ok, policy} =
      new(%{
        version: @version,
        max_infrastructure_retries: 2,
        max_repairs: 2,
        max_elapsed_ms: 3_600_000,
        max_spend_usd: routine.max_budget_usd || 1.0
      })

    policy
  end

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = atomize(attrs)

    policy = %__MODULE__{
      version: attrs[:version] || @version,
      max_infrastructure_retries: attrs[:max_infrastructure_retries],
      max_repairs: attrs[:max_repairs],
      max_elapsed_ms: attrs[:max_elapsed_ms],
      max_spend_usd: attrs[:max_spend_usd]
    }

    with :ok <- nonempty(:version, policy.version),
         :ok <- nonnegative(:max_infrastructure_retries, policy.max_infrastructure_retries),
         :ok <- nonnegative(:max_repairs, policy.max_repairs),
         :ok <- positive(:max_elapsed_ms, policy.max_elapsed_ms),
         :ok <- positive_number(:max_spend_usd, policy.max_spend_usd) do
      {:ok, policy}
    end
  end

  def new(_attrs), do: {:error, :invalid_repair_policy}

  @spec evaluate(Attempt.t(), map(), [Attempt.t()], WorkItem.t(), t(), DateTime.t()) ::
          {:ok, Disposition.t(), map()}
          | {:exhausted, Disposition.t(), map(), map()}
          | {:error, term()}
  def evaluate(
        %Attempt{} = failed,
        focused_failure,
        attempts,
        %WorkItem{} = work_item,
        %__MODULE__{} = policy,
        %DateTime{} = now
      )
      when is_map(focused_failure) and is_list(attempts) do
    with {:ok, disposition} <- classify(failed, focused_failure) do
      usage = usage(attempts, work_item, now)
      snapshot = %{policy: render(policy), usage: usage}

      case exhausted_limit(disposition, usage, policy) do
        nil -> {:ok, disposition, snapshot}
        limit -> {:exhausted, disposition, snapshot, limit}
      end
    end
  end

  @spec render(t()) :: map()
  def render(%__MODULE__{} = policy), do: Map.from_struct(policy)

  defp classify(failed, focused_failure) do
    classification = get_in(failed.outcome || %{}, ["classification"]) || failed.error_class
    purpose = get_in(failed.provenance || %{}, ["purpose"])
    prior_disposition = get_in(failed.provenance || %{}, ["repair_disposition", "kind"])

    {kind, reason, handler, question} =
      disposition_spec(
        classification,
        purpose,
        prior_disposition,
        focused_failure,
        failed
      )

    Disposition.new(
      disposition_attrs(
        failed,
        focused_failure,
        kind,
        reason,
        handler,
        question
      )
    )
  end

  defp disposition_spec(classification, _purpose, _prior, _focused, _failed)
       when classification in @infrastructure_classes do
    {
      "infrastructure_retry",
      "retry the deterministic verification boundary",
      "verification_retry",
      nil
    }
  end

  defp disposition_spec("human_question", _purpose, _prior, _focused, failed) do
    {
      "human_ask",
      "operator input is required before repair can continue",
      nil,
      question(failed)
    }
  end

  defp disposition_spec("policy_refusal", _purpose, _prior, _focused, _failed) do
    {
      "terminal_block",
      "verification policy refused the current workspace",
      nil,
      nil
    }
  end

  defp disposition_spec("cancellation", _purpose, _prior, _focused, _failed) do
    {
      "terminal_block",
      "verification was cancelled and cannot be resumed automatically",
      nil,
      nil
    }
  end

  defp disposition_spec(
         _classification,
         "github_issue_repair",
         "mechanical_repair",
         _focused,
         _failed
       ) do
    {
      "semantic_repair",
      "the reviewed mechanical repair did not resolve the failure",
      "claude",
      nil
    }
  end

  defp disposition_spec(classification, _purpose, _prior, focused, _failed)
       when classification in ~w(test_failure semantic_follow_up) do
    if mechanical_failure?(focused) do
      {
        "mechanical_repair",
        "all focused failures are covered by the reviewed formatter",
        "elixir_format",
        nil
      }
    else
      {
        "semantic_repair",
        "focused semantic work is required to satisfy verification",
        "claude",
        nil
      }
    end
  end

  defp disposition_spec(_classification, _purpose, _prior, _focused, _failed) do
    {
      "terminal_block",
      "the failure has no approved automated repair path",
      nil,
      nil
    }
  end

  defp disposition_attrs(failed, focused_failure, kind, reason, handler, question) do
    %{
      kind: kind,
      reason: reason,
      source_attempt_id: failed.attempt_id,
      failure_artifact_id: failure_artifact_id(failed, focused_failure),
      handler: handler,
      question: question
    }
  end

  defp failure_artifact_id(failed, focused_failure) do
    focused_failure["artifact_id"] ||
      get_in(failed.outcome || %{}, ["artifacts", "failure_artifact_id"]) ||
      get_in(failed.outcome || %{}, ["artifacts", "provider_checkpoint_artifact_id"])
  end

  defp mechanical_failure?(%{"failures" => failures}) when is_list(failures) and failures != [] do
    Enum.all?(failures, fn failure ->
      failure["category"] == "format" and failure["status"] == "test_failure"
    end)
  end

  defp mechanical_failure?(_focused_failure), do: false

  defp question(failed) do
    get_in(failed.error_details || %{}, ["question"]) ||
      get_in(failed.outcome || %{}, ["structured_output", "question"]) ||
      get_in(failed.outcome || %{}, ["summary"]) ||
      "What input is required to continue?"
  end

  defp usage(attempts, work_item, now) do
    repairs =
      Enum.filter(attempts, fn attempt ->
        get_in(attempt.provenance || %{}, ["purpose"]) == "github_issue_repair"
      end)

    %{
      infrastructure_retries:
        Enum.count(
          repairs,
          &(get_in(&1.provenance, ["repair_disposition", "kind"]) ==
              "infrastructure_retry")
        ),
      repairs:
        Enum.count(
          repairs,
          &(get_in(&1.provenance, ["repair_disposition", "kind"]) in @repair_kinds)
        ),
      elapsed_ms: max(DateTime.diff(now, work_item.inserted_at, :millisecond), 0),
      spend_usd: Enum.reduce(attempts, 0.0, &(&2 + cost(&1)))
    }
  end

  defp exhausted_limit(_disposition, usage, policy)
       when usage.elapsed_ms >= policy.max_elapsed_ms do
    limit("elapsed_ms", policy.max_elapsed_ms, usage.elapsed_ms)
  end

  defp exhausted_limit(_disposition, usage, policy)
       when usage.spend_usd >= policy.max_spend_usd do
    limit("spend_usd", policy.max_spend_usd, usage.spend_usd)
  end

  defp exhausted_limit(%{kind: "infrastructure_retry"}, usage, policy)
       when usage.infrastructure_retries >= policy.max_infrastructure_retries do
    limit(
      "infrastructure_retries",
      policy.max_infrastructure_retries,
      usage.infrastructure_retries
    )
  end

  defp exhausted_limit(%{kind: kind}, usage, policy)
       when kind in @repair_kinds and usage.repairs >= policy.max_repairs do
    limit("repairs", policy.max_repairs, usage.repairs)
  end

  defp exhausted_limit(_disposition, _usage, _policy), do: nil

  defp limit(name, allowed, observed),
    do: %{name: name, allowed: allowed, observed: observed}

  defp cost(attempt) do
    case get_in(attempt.usage || %{}, ["cost_usd"]) do
      value when is_number(value) -> value
      _missing -> 0.0
    end
  end

  defp nonempty(_field, value) when is_binary(value) and value != "", do: :ok
  defp nonempty(field, _value), do: {:error, {:repair_policy_field_required, field}}

  defp nonnegative(_field, value) when is_integer(value) and value >= 0, do: :ok
  defp nonnegative(field, value), do: {:error, {:invalid_repair_policy_limit, field, value}}

  defp positive(_field, value) when is_integer(value) and value > 0, do: :ok
  defp positive(field, value), do: {:error, {:invalid_repair_policy_limit, field, value}}

  defp positive_number(_field, value) when is_number(value) and value > 0, do: :ok

  defp positive_number(field, value),
    do: {:error, {:invalid_repair_policy_limit, field, value}}

  defp atomize(attrs) do
    attrs
    |> Map.new()
    |> Map.new(fn
      {key, value} when is_binary(key) ->
        case key do
          "version" -> {:version, value}
          "max_infrastructure_retries" -> {:max_infrastructure_retries, value}
          "max_repairs" -> {:max_repairs, value}
          "max_elapsed_ms" -> {:max_elapsed_ms, value}
          "max_spend_usd" -> {:max_spend_usd, value}
          _other -> {key, value}
        end

      pair ->
        pair
    end)
  end
end
