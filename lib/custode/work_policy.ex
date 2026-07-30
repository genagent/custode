defmodule Custode.WorkPolicy do
  @moduledoc """
  Deterministic selection of typed, versioned work-control posture and limits.

  Policy is a narrowing layer. It does not mint operation grants and never
  replaces the operation authorization adapter, Gate checks, leases, or
  WorkItem preconditions.
  """

  alias Custode.Repair.Policy, as: RepairPolicy
  alias Custode.WorkItem
  alias Custode.WorkPolicy.{Decision, Definition}

  @type registry :: [Definition.t()]

  @doc "Validate and deterministically order an immutable policy set."
  @spec new([Definition.t()]) :: {:ok, registry()} | {:error, term()}
  def new(definitions) when is_list(definitions) do
    definitions
    |> Enum.reduce_while({:ok, %{}}, fn
      %Definition{} = definition, {:ok, acc} ->
        identity = Definition.identity(definition)

        if Map.has_key?(acc, identity) do
          {:halt, {:error, {:duplicate_work_policy, identity}}}
        else
          {:cont, {:ok, Map.put(acc, identity, definition)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_work_policy_definition}}
    end)
    |> case do
      {:ok, by_identity} ->
        {:ok,
         by_identity
         |> Map.values()
         |> Enum.sort_by(&Definition.identity/1)}

      {:error, _reason} = error ->
        error
    end
  end

  def new(_definitions), do: {:error, :invalid_work_policy_registry}

  @doc "Select the single most-specific matching rule."
  @spec select(registry(), map()) :: {:ok, Decision.t()} | {:error, term()}
  def select(definitions, inputs) when is_list(definitions) and is_map(inputs) do
    inputs = normalize_keys(inputs)
    version = value(inputs, :policy_version)

    candidates =
      definitions
      |> Enum.filter(&(&1.version == version and matches?(&1.selectors, inputs)))
      |> Enum.group_by(&map_size(&1.selectors))

    case candidates |> Map.keys() |> Enum.max(fn -> nil end) do
      nil ->
        {:error, {:work_policy_not_found, inputs}}

      specificity ->
        select_candidate(Map.fetch!(candidates, specificity), inputs)
    end
  end

  def select(_definitions, _inputs), do: {:error, :invalid_work_policy_selection}

  @doc """
  Build the compatibility policy for one current golden-path decision.

  Existing routine knobs remain the source of the initial values. The returned
  decision freezes them for the Attempt instead of rereading mutable routine
  configuration during provider launch.
  """
  @spec compatibility(map(), WorkItem.t(), keyword()) ::
          {:ok, Decision.t()} | {:error, term()}
  def compatibility(routine, %WorkItem{} = work_item, options \\ []) when is_map(routine) do
    execution = %{
      provider: Keyword.get(options, :provider, "custode"),
      selection: Keyword.get(options, :selection, %{}),
      limits: %{
        max_turns: routine.max_turns,
        timeout_ms: routine.timeout_ms,
        max_context_tokens: Keyword.get(options, :max_context_tokens)
      },
      max_concurrency:
        Keyword.get_lazy(options, :max_concurrency, fn ->
          compatibility_concurrency(Keyword.get(options, :provider, "custode"))
        end)
    }

    repair = RepairPolicy.default(routine) |> RepairPolicy.render()

    controls = %{
      quality: %{
        verification: %{required: true, source: "existing_recipe"},
        review: %{depth: "existing"}
      },
      budget: %{
        max_spend_usd: routine.max_budget_usd,
        daily_budget_usd: routine.daily_budget_usd,
        daily_budget_tokens: routine.daily_budget_tokens
      },
      execution: execution,
      retry: %{
        max_infrastructure_retries: repair.max_infrastructure_retries,
        max_repairs: repair.max_repairs,
        max_elapsed_ms: repair.max_elapsed_ms,
        max_spend_usd: repair.max_spend_usd
      }
    }

    decide(work_item, controls, options)
  end

  @doc "Build the compatibility policy for deterministic intake."
  @spec intake(WorkItem.t(), atom(), keyword()) :: {:ok, Decision.t()} | {:error, term()}
  def intake(%WorkItem{} = work_item, disposition, options \\ [])
      when disposition in [:eligible, :ineligible, :closed] do
    controls = %{
      quality: %{
        verification: %{required: true, source: "existing_recipe"},
        review: %{depth: "existing"}
      },
      budget: %{
        max_spend_usd: nil,
        daily_budget_usd: nil,
        daily_budget_tokens: nil
      },
      execution: %{
        provider: "custode",
        selection: %{},
        limits: %{max_turns: nil, timeout_ms: nil, max_context_tokens: nil},
        max_concurrency: 1
      },
      retry: %{
        max_infrastructure_retries: 0,
        max_repairs: 0,
        max_elapsed_ms: nil,
        max_spend_usd: nil
      }
    }

    phase = if(disposition == :ineligible, do: "ineligible", else: work_item.phase)
    decide(work_item, controls, Keyword.put(options, :phase, phase))
  end

  @doc "Build the compatibility posture for a typed operation."
  @spec operation(WorkItem.t(), atom(), keyword()) :: {:ok, Decision.t()} | {:error, term()}
  def operation(%WorkItem{} = work_item, risk, options \\ [])
      when risk in [:read, :internal_write, :external_write, :destructive] do
    controls = %{
      quality: %{
        verification: %{required: true, source: "existing_recipe"},
        review: %{depth: "existing"}
      },
      budget: %{
        max_spend_usd: nil,
        daily_budget_usd: nil,
        daily_budget_tokens: nil
      },
      execution: %{
        provider: "custode",
        selection: %{},
        limits: %{max_turns: nil, timeout_ms: nil, max_context_tokens: nil},
        max_concurrency: 1
      },
      retry: %{
        max_infrastructure_retries: 0,
        max_repairs: 0,
        max_elapsed_ms: nil,
        max_spend_usd: nil
      }
    }

    decide(work_item, controls, Keyword.put(options, :risk, risk))
  end

  @spec render(Decision.t()) :: map()
  def render(%Decision{} = decision), do: Decision.render(decision)

  @doc "Read a persisted policy posture without creating atoms from external data."
  @spec posture(map() | nil) :: Definition.posture() | :invalid | nil
  def posture(policy) when is_map(policy) do
    case value(policy, :posture) do
      :auto -> :auto
      "auto" -> :auto
      :ask -> :ask
      "ask" -> :ask
      :ineligible -> :ineligible
      "ineligible" -> :ineligible
      _unknown -> :invalid
    end
  end

  def posture(_policy), do: nil

  @doc "Return the exact controls frozen into a rendered decision."
  @spec controls(map() | nil) :: map()
  def controls(policy) when is_map(policy) do
    case value(policy, :controls) do
      controls when is_map(controls) -> controls
      _missing -> %{}
    end
  end

  def controls(_policy), do: %{}

  defp decide(work_item, controls, options) do
    inputs = inputs(work_item, options)
    version = inputs.policy_version

    with :ok <- policy_version(version),
         {:ok, definitions} <- compatibility_definitions(version, work_item, controls) do
      select(definitions, inputs)
    end
  end

  defp compatibility_definitions(version, work_item, controls) do
    base_selectors = %{
      work_kind: work_item.kind,
      workflow_version: work_item.workflow_version
    }

    definitions = [
      definition!(
        "compatibility.ineligible",
        version,
        Map.put(base_selectors, :phase, "ineligible"),
        :ineligible,
        controls,
        "the WorkItem remains visible but current policy does not admit execution"
      ),
      definition!(
        "compatibility.external_write",
        version,
        Map.put(base_selectors, :risk, :external_write),
        :ask,
        controls,
        "existing external writes remain protected by an operator Gate"
      ),
      definition!(
        "compatibility.destructive",
        version,
        Map.put(base_selectors, :risk, :destructive),
        :ask,
        controls,
        "destructive operations require an operator Gate"
      ),
      definition!(
        "compatibility.auto",
        version,
        base_selectors,
        :auto,
        controls,
        "existing eligible deterministic and bounded execution remains automatic"
      )
    ]

    new(definitions)
  end

  defp definition!(name, version, selectors, posture, controls, reason) do
    gates = %{
      required: posture == :ask,
      risks: if(posture == :ask, do: ["external_write", "destructive"], else: [])
    }

    {:ok, definition} =
      Definition.new(
        name: name,
        version: version,
        selectors: selectors,
        posture: posture,
        quality: controls.quality,
        budget: controls.budget,
        execution: controls.execution,
        retry: controls.retry,
        gates: gates,
        reason: reason
      )

    definition
  end

  defp inputs(work_item, options) do
    source = Keyword.get(options, :source_snapshot, %{})

    %{
      policy_version: work_item.policy_ref || work_item.mission.policy_ref,
      mission_id: work_item.mission.mission_id,
      work_kind: work_item.kind,
      workflow_version: work_item.workflow_version,
      phase: Keyword.get(options, :phase, work_item.phase),
      risk: Keyword.get(options, :risk),
      target: Keyword.get(options, :target),
      repository:
        Keyword.get(options, :repository) ||
          value(source, :canonical_name) ||
          get_in(source, ["issue", "repository"])
    }
  end

  defp policy_version(version) when is_binary(version) and version != "", do: :ok
  defp policy_version(_version), do: {:error, :work_policy_version_required}

  defp select_candidate([definition], inputs), do: {:ok, Decision.new(definition, inputs)}

  defp select_candidate(definitions, _inputs) do
    matches =
      definitions
      |> Enum.map(&%{name: &1.name, version: &1.version, selectors: &1.selectors})
      |> Enum.sort_by(&{&1.name, &1.version})

    {:error, {:ambiguous_work_policy, matches}}
  end

  defp matches?(selectors, inputs) do
    Enum.all?(selectors, fn {key, expected} ->
      comparable(value(inputs, key)) == comparable(expected)
    end)
  end

  defp comparable(value) when is_atom(value), do: Atom.to_string(value)
  defp comparable(value), do: value

  defp compatibility_concurrency("claude"), do: configured_concurrency(:claude)
  defp compatibility_concurrency("codex"), do: configured_concurrency(:codex)
  defp compatibility_concurrency(_provider), do: configured_concurrency(:custode)

  defp configured_concurrency(provider) do
    :custode
    |> Application.get_env(:attempt_worker_limits, [])
    |> Keyword.get(provider, 3)
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, item} -> {known_key(key), normalize_value(item)} end)
  end

  defp normalize_value(map) when is_map(map), do: normalize_keys(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp known_key(key) when is_atom(key), do: key

  defp known_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
