defmodule Custode.WorkKinds.SystemicDriftControl.V1 do
  @moduledoc """
  Version 1 phase and decision contract for control work raised from
  systemic-drift Observations (#246).

  ## This kind never dispatches itself

  Every state except `waiting` and `blocked` answers `next_command/2` with
  `%{action: :none}`. A control WorkItem is a bounded, evidence-linked record
  that drift crossed a threshold and what the operator decided about it. It
  does not start Attempts, and nothing here can cause one.

  That is deliberate rather than unfinished. The failure mode a control
  pathway invites is a loop: drift raises work, the work produces activity,
  the activity looks like drift. Refusing to self-dispatch removes the engine
  from that loop entirely, and leaves remediation to be proposed the same way
  any other work is.

  ## Phases

      observed            the threshold was met and the record exists
      awaiting_decision   an operator decision is pending behind a Gate
      admitted            the operator accepted it as real drift
      declined            the operator rejected it, visibly and for a reason
      resolved            the drift no longer holds

  `declined` is a phase rather than a deletion. An observation that silently
  disappears is indistinguishable from one that was never made.
  """

  @behaviour Custode.WorkKind

  alias Custode.WorkItem

  @phases ~w(observed awaiting_decision admitted declined resolved)

  @state_phases %{
    "proposed" => ~w(observed),
    "waiting" => ~w(awaiting_decision),
    "ready" => ~w(admitted),
    "active" => ~w(admitted),
    "blocked" => @phases,
    "completed" => ~w(resolved),
    "cancelled" => ~w(declined)
  }

  @phase_edges %{
    "observed" => ~w(awaiting_decision admitted declined),
    "awaiting_decision" => ~w(admitted declined),
    "admitted" => ~w(resolved declined),
    "declined" => ~w(),
    "resolved" => ~w()
  }

  @impl Custode.WorkKind
  def kind, do: "systemic_drift_control"

  @impl Custode.WorkKind
  def version, do: 1

  @impl Custode.WorkKind
  def phases, do: @phases

  @impl Custode.WorkKind
  def validate_pair(state, phase) do
    cond do
      phase not in @phases -> {:error, {:unknown_phase, phase}}
      phase in Map.get(@state_phases, state, []) -> :ok
      true -> {:error, {:illegal_state_phase, %{state: state, phase: phase}}}
    end
  end

  @impl Custode.WorkKind
  def validate_transition(%WorkItem{} = work_item, target, _evidence) do
    to_state = value(target, :state) || work_item.state
    to_phase = value(target, :phase) || work_item.phase

    with :ok <- validate_pair(to_state, to_phase) do
      validate_phase_edge(work_item.phase, to_phase)
    end
  end

  @impl Custode.WorkKind
  def next_command(%WorkItem{state: "waiting", waiting_condition: condition}, _world_snapshot),
    do: {:ok, %{action: :wait, condition: condition}}

  def next_command(%WorkItem{state: "blocked", blocked_reason: reason}, _world_snapshot),
    do: {:ok, %{action: :blocked, reason: reason}}

  def next_command(%WorkItem{state: state}, _world_snapshot)
      when state in ["completed", "cancelled"],
      do: {:ok, %{action: :none, reason: :terminal}}

  # Admitted control work is a record a human acts on, not a queue the fleet
  # drains. Answering :none here is what keeps the drift loop open-circuit.
  def next_command(%WorkItem{}, _world_snapshot),
    do: {:ok, %{action: :none, reason: :operator_led}}

  defp validate_phase_edge(phase, phase), do: :ok

  defp validate_phase_edge(from, to) do
    if to in Map.get(@phase_edges, from, []) do
      :ok
    else
      {:error, {:illegal_phase_transition, %{from: from, to: to}}}
    end
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
