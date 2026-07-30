defmodule Custode.WorkPolicy.Definition do
  @moduledoc """
  One immutable, versioned work-control rule.

  Selectors are exact matches. Omitted selectors are wildcards, which keeps
  policy selection deterministic and inspectable without introducing a rule
  language.
  """

  @selector_keys ~w(mission_id work_kind workflow_version phase risk target repository)a
  @postures [:auto, :ask, :ineligible]

  @enforce_keys [
    :name,
    :version,
    :selectors,
    :posture,
    :quality,
    :budget,
    :execution,
    :retry,
    :gates,
    :reason
  ]
  defstruct @enforce_keys

  @type posture :: :auto | :ask | :ineligible

  @type t :: %__MODULE__{
          name: String.t(),
          version: String.t(),
          selectors: map(),
          posture: posture(),
          quality: map(),
          budget: map(),
          execution: map(),
          retry: map(),
          gates: map(),
          reason: String.t()
        }

  @spec new(map() | keyword()) :: {:ok, t()} | {:error, term()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    definition =
      struct(__MODULE__,
        name: value(attrs, :name),
        version: value(attrs, :version),
        selectors: normalize_keys(value(attrs, :selectors) || %{}),
        posture: normalize_posture(value(attrs, :posture)),
        quality: normalize_keys(value(attrs, :quality) || %{}),
        budget: normalize_keys(value(attrs, :budget) || %{}),
        execution: normalize_keys(value(attrs, :execution) || %{}),
        retry: normalize_keys(value(attrs, :retry) || %{}),
        gates: normalize_keys(value(attrs, :gates) || %{}),
        reason: value(attrs, :reason)
      )

    with :ok <- nonempty(:name, definition.name),
         :ok <- nonempty(:version, definition.version),
         :ok <- selectors(definition.selectors),
         :ok <- posture(definition.posture),
         :ok <- controls(definition),
         :ok <- nonempty(:reason, definition.reason) do
      {:ok, definition}
    end
  rescue
    KeyError -> {:error, :invalid_work_policy_definition}
  end

  def new(_attrs), do: {:error, :invalid_work_policy_definition}

  @spec identity(t()) :: {String.t(), String.t(), list()}
  def identity(%__MODULE__{} = definition) do
    {definition.name, definition.version, canonical(definition.selectors)}
  end

  @spec render(t()) :: map()
  def render(%__MODULE__{} = definition) do
    %{
      name: definition.name,
      version: definition.version,
      selectors: definition.selectors,
      posture: Atom.to_string(definition.posture),
      controls: %{
        quality: definition.quality,
        budget: definition.budget,
        execution: definition.execution,
        retry: definition.retry,
        gates: definition.gates
      },
      reason: definition.reason
    }
  end

  def selector_keys, do: @selector_keys

  defp selectors(selectors) when is_map(selectors) and map_size(selectors) > 0 do
    unknown = Map.keys(selectors) -- @selector_keys

    cond do
      unknown != [] -> {:error, {:unknown_work_policy_selectors, Enum.sort(unknown)}}
      Enum.any?(selectors, fn {_key, item} -> is_nil(item) end) -> {:error, :invalid_selector}
      true -> :ok
    end
  end

  defp selectors(_selectors), do: {:error, :work_policy_selectors_required}

  defp posture(value) when value in @postures, do: :ok
  defp posture(value), do: {:error, {:invalid_work_policy_posture, value}}

  defp controls(definition) do
    with :ok <- map_control(:quality, definition.quality),
         :ok <- map_control(:budget, definition.budget),
         :ok <- map_control(:execution, definition.execution),
         :ok <- map_control(:retry, definition.retry),
         :ok <- map_control(:gates, definition.gates),
         :ok <- bounded_retry(definition.retry) do
      gate_posture(definition.posture, definition.gates)
    end
  end

  defp map_control(_name, value) when is_map(value), do: :ok
  defp map_control(name, _value), do: {:error, {:invalid_work_policy_control, name}}

  defp bounded_retry(retry) do
    with :ok <- nonnegative_limit(retry, :max_infrastructure_retries) do
      nonnegative_limit(retry, :max_repairs)
    end
  end

  defp nonnegative_limit(map, field) do
    case Map.get(map, field) do
      value when is_integer(value) and value >= 0 -> :ok
      value -> {:error, {:invalid_work_policy_limit, field, value}}
    end
  end

  defp gate_posture(:ask, %{required: true}), do: :ok
  defp gate_posture(:ask, _gates), do: {:error, :ask_policy_requires_gate}
  defp gate_posture(_posture, %{required: value}) when is_boolean(value), do: :ok
  defp gate_posture(_posture, _gates), do: {:error, :work_policy_gate_requirement_missing}

  defp nonempty(_field, value) when is_binary(value) and value != "", do: :ok
  defp nonempty(field, _value), do: {:error, {:work_policy_field_required, field}}

  defp normalize_posture(value) when value in @postures, do: value

  defp normalize_posture(value) when is_binary(value) do
    case value do
      "auto" -> :auto
      "ask" -> :ask
      "ineligible" -> :ineligible
      _other -> value
    end
  end

  defp normalize_posture(value), do: value

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn {key, item} ->
      {known_key(key), normalize_value(item)}
    end)
  end

  defp normalize_keys(value), do: value

  defp normalize_value(map) when is_map(map), do: normalize_keys(map)
  defp normalize_value(list) when is_list(list), do: Enum.map(list, &normalize_value/1)
  defp normalize_value(value), do: value

  defp known_key(key) when is_atom(key), do: key

  defp known_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {key, item} -> {to_string(key), canonical(item)} end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
