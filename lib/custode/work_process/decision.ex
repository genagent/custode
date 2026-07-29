defmodule Custode.WorkProcess.Decision do
  @moduledoc """
  A validated, transport-neutral next action for one WorkItem version.

  Decisions contain durable identifiers and exact transition or operation
  specifications. They never contain provider conversation state or executable
  functions.
  """

  alias Custode.{WorkItem, WorkKinds}

  @effectful ~w(dispatch_attempt invoke_operation open_gate transition)
  @idle ~w(wait observe none reconcile blocked)
  @actions @effectful ++ @idle

  @enforce_keys [:action]
  defstruct [:action, :attempt, :operation, :gate, :transition, :reason]

  @type t :: %__MODULE__{
          action: String.t(),
          attempt: map() | nil,
          operation: map() | nil,
          gate: map() | nil,
          transition: map() | nil,
          reason: term()
        }

  @spec new(map(), WorkItem.t()) :: {:ok, t()} | {:error, term()}
  def new(command, %WorkItem{} = work_item) when is_map(command) do
    command = atomize(command)
    action = command[:action] |> normalize_action()

    with :ok <- known_action(action),
         {:ok, decision} <- build(action, command),
         :ok <- validate_transition(decision.transition, work_item) do
      {:ok, decision}
    end
  end

  def new(_command, _work_item), do: {:error, :invalid_process_decision}

  @spec effectful?(t()) :: boolean()
  def effectful?(%__MODULE__{action: action}), do: action in @effectful

  @spec render(t()) :: map()
  def render(%__MODULE__{} = decision) do
    decision
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @spec restore(map(), WorkItem.t()) :: {:ok, t()} | {:error, term()}
  def restore(value, work_item), do: new(value, work_item)

  defp build("dispatch_attempt", command) do
    with {:ok, attempt} <- required_map(command[:attempt], :attempt),
         {:ok, transition} <- required_map(command[:transition], :transition),
         "active" <- value(transition, :state) do
      {:ok,
       %__MODULE__{
         action: "dispatch_attempt",
         attempt: attempt,
         transition: transition
       }}
    else
      {:error, _reason} = error -> error
      _state -> {:error, {:invalid_process_decision, :attempt_transition_must_be_active}}
    end
  end

  defp build("invoke_operation", command) do
    with {:ok, operation} <- required_map(command[:operation], :operation) do
      {:ok,
       %__MODULE__{
         action: "invoke_operation",
         operation: operation,
         transition: optional_map(command[:transition]),
         reason: command[:reason]
       }}
    end
  end

  defp build("open_gate", command) do
    with {:ok, gate} <- required_map(command[:gate], :gate) do
      {:ok, %__MODULE__{action: "open_gate", gate: gate, reason: command[:reason]}}
    end
  end

  defp build("transition", command) do
    with {:ok, transition} <- required_map(command[:transition], :transition) do
      {:ok, %__MODULE__{action: "transition", transition: transition, reason: command[:reason]}}
    end
  end

  defp build(action, command) when action in @idle do
    {:ok, %__MODULE__{action: action, reason: command[:reason] || command[:condition]}}
  end

  defp validate_transition(nil, _work_item), do: :ok

  defp validate_transition(transition, work_item) do
    transition = atomize(transition)
    state = transition[:state]
    phase = transition[:phase]

    if is_binary(state) and is_binary(phase) do
      WorkKinds.validate_pair(work_item.kind, work_item.workflow_version, state, phase)
    else
      {:error, {:invalid_process_decision, :transition_state_and_phase_required}}
    end
  end

  defp known_action(action) when action in @actions, do: :ok
  defp known_action(action), do: {:error, {:unknown_process_action, action}}

  defp normalize_action(action) when is_atom(action), do: Atom.to_string(action)
  defp normalize_action(action) when is_binary(action), do: action
  defp normalize_action(action), do: action

  defp required_map(value, _field) when is_map(value) and map_size(value) > 0, do: {:ok, value}
  defp required_map(_value, field), do: {:error, {:invalid_process_decision, field}}

  defp optional_map(value) when is_map(value) and map_size(value) > 0, do: value
  defp optional_map(_value), do: nil

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp atomize(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) ->
        try do
          {String.to_existing_atom(key), value}
        rescue
          ArgumentError -> {key, value}
        end

      pair ->
        pair
    end)
  end
end
