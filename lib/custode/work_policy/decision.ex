defmodule Custode.WorkPolicy.Decision do
  @moduledoc "The exact, replayable result of selecting one WorkPolicy definition."

  alias Custode.WorkPolicy.Definition

  @enforce_keys [
    :name,
    :version,
    :posture,
    :inputs,
    :matched_selectors,
    :controls,
    :explanation,
    :fingerprint
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          posture: Definition.posture(),
          inputs: map(),
          matched_selectors: map(),
          controls: map(),
          explanation: map(),
          fingerprint: String.t()
        }

  @spec new(Definition.t(), map()) :: t()
  def new(%Definition{} = definition, inputs) when is_map(inputs) do
    controls = %{
      quality: definition.quality,
      budget: definition.budget,
      execution: definition.execution,
      retry: definition.retry,
      gates: definition.gates
    }

    decision = %__MODULE__{
      name: definition.name,
      version: definition.version,
      posture: definition.posture,
      inputs: inputs,
      matched_selectors: definition.selectors,
      controls: controls,
      explanation: %{
        policy: definition.name,
        version: definition.version,
        reason: definition.reason,
        matched_selectors: definition.selectors,
        specificity: map_size(definition.selectors)
      },
      fingerprint: ""
    }

    %{decision | fingerprint: fingerprint(decision)}
  end

  @spec render(t()) :: map()
  def render(%__MODULE__{} = decision) do
    %{
      name: decision.name,
      version: decision.version,
      posture: Atom.to_string(decision.posture),
      inputs: decision.inputs,
      matched_selectors: decision.matched_selectors,
      controls: decision.controls,
      explanation: decision.explanation,
      fingerprint: decision.fingerprint
    }
  end

  @spec fingerprint(t()) :: String.t()
  def fingerprint(%__MODULE__{} = decision) do
    decision
    |> Map.from_struct()
    |> Map.delete(:fingerprint)
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value) when is_atom(value), do: Atom.to_string(value)
  defp canonical(value), do: value
end
