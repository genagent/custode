defmodule Custode.WorkItems do
  @moduledoc """
  WorkItem identity, optimistic transitions, explicit reopen, and typed events.

  Mutable WorkItems remain current truth. Every lifecycle change and its
  operation provenance is appended to WorkEvents in the same transaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Mission,
    Missions,
    OperationCall,
    OperationEnvelope,
    Repo,
    WorkEvent,
    WorkItem,
    WorkKinds
  }

  @states ~w(proposed ready active waiting blocked completed cancelled)
  @terminal ~w(completed cancelled)
  @active_call_statuses ~w(proposed waiting running)

  @transitions %{
    "proposed" => ~w(ready waiting blocked completed cancelled),
    "ready" => ~w(active waiting blocked completed cancelled),
    "active" => ~w(ready waiting blocked completed cancelled),
    "waiting" => ~w(ready blocked completed cancelled),
    "blocked" => ~w(proposed ready waiting completed cancelled),
    "completed" => [],
    "cancelled" => []
  }

  @spec list() :: [WorkItem.t()]
  def list do
    WorkItem
    |> Repo.all()
    |> Repo.preload([:mission, :parent])
  end

  @spec list_for_mission(String.t()) :: [WorkItem.t()]
  def list_for_mission(mission_id) do
    case Missions.get(mission_id) do
      nil ->
        []

      mission ->
        from(work_item in WorkItem,
          where: work_item.mission_id == ^mission.id,
          order_by: [asc: work_item.inserted_at]
        )
        |> Repo.all()
        |> Repo.preload([:mission, :parent])
    end
  end

  @spec get(String.t()) :: WorkItem.t() | nil
  def get(work_item_id) do
    WorkItem
    |> Repo.get_by(work_item_id: work_item_id)
    |> preload()
  end

  @spec get_by_source(String.t(), String.t()) :: WorkItem.t() | nil
  def get_by_source(source, external_key) do
    WorkItem
    |> Repo.get_by(source: source, external_key: external_key)
    |> preload()
  end

  @spec list_events(String.t()) :: [WorkEvent.t()]
  def list_events(work_item_id) do
    case get(work_item_id) do
      nil ->
        []

      work_item ->
        from(event in WorkEvent,
          where: event.work_item_id == ^work_item.id,
          order_by: [asc: event.work_item_version, asc: event.inserted_at, asc: event.id]
        )
        |> Repo.all()
    end
  end

  @doc false
  def create(attrs, %OperationEnvelope{} = envelope) do
    attrs = atomize(attrs)

    Repo.transaction(fn ->
      mission = active_mission!(attrs[:mission_id])
      parent = parent!(attrs[:parent_work_item_id], mission)
      state = "proposed"
      phase = attrs[:phase]

      rollback_unless_ok(
        WorkKinds.validate_pair(attrs[:kind], attrs[:workflow_version], state, phase)
      )

      rollback_unless(structured?(attrs[:acceptance_criteria]), :acceptance_criteria_required)

      create_attrs = %{
        work_item_id: Ecto.UUID.generate(),
        mission_id: mission.id,
        parent_id: parent && parent.id,
        kind: attrs[:kind],
        workflow_version: attrs[:workflow_version],
        objective: attrs[:objective],
        acceptance_criteria: normalize(attrs[:acceptance_criteria]),
        state: state,
        phase: phase,
        priority: attrs[:priority] || 0,
        policy_ref: attrs[:policy_ref] || mission.policy_ref,
        source: attrs[:source],
        external_key: attrs[:external_key],
        version: 1
      }

      case Repo.insert(WorkItem.create_changeset(create_attrs)) do
        {:ok, work_item} ->
          work_item = preload(work_item)
          event = append_event!(work_item, nil, "work_item.created", attrs[:evidence], envelope)
          {:created, work_item, event}

        {:error, changeset} ->
          handle_create_error!(changeset, attrs[:source], attrs[:external_key])
      end
    end)
    |> unwrap_create()
  end

  @doc false
  def transition(work_item_id, attrs, %OperationEnvelope{} = envelope) do
    attrs = atomize(attrs)

    Repo.transaction(
      fn ->
        work_item = work_item!(work_item_id)
        active_mission!(work_item.mission.mission_id)
        expected_version = attrs[:expected_version]
        ensure_version!(work_item, expected_version)

        target = transition_target(work_item, attrs)
        evidence = normalize(attrs[:evidence] || %{})
        validate_generic_transition!(work_item, target)
        validate_state_details!(work_item, target, envelope)

        rollback_unless_ok(WorkKinds.validate_transition(work_item, target, evidence))

        apply_change!(
          work_item,
          target,
          expected_version,
          "work_item.transitioned",
          evidence,
          envelope
        )
      end,
      mode: :immediate
    )
    |> unwrap_change()
  end

  @doc false
  def reopen(work_item_id, attrs, %OperationEnvelope{} = envelope) do
    attrs = atomize(attrs)

    Repo.transaction(
      fn ->
        work_item = work_item!(work_item_id)
        active_mission!(work_item.mission.mission_id)
        expected_version = attrs[:expected_version]
        ensure_version!(work_item, expected_version)
        rollback_unless(work_item.state in @terminal, :work_item_not_terminal)
        rollback_unless(structured?(attrs[:reason]), :reopen_reason_required)
        rollback_unless(structured?(attrs[:acceptance_review]), :acceptance_review_required)

        acceptance_criteria = attrs[:acceptance_criteria] || work_item.acceptance_criteria
        rollback_unless(structured?(acceptance_criteria), :acceptance_criteria_required)

        target =
          work_item
          |> transition_target(attrs)
          |> Map.put(:acceptance_criteria, normalize(acceptance_criteria))

        rollback_unless(target.state in (@states -- ["active", "completed", "cancelled"]), {
          :illegal_reopen_state,
          target.state
        })

        rollback_unless_ok(
          WorkKinds.validate_pair(
            work_item.kind,
            work_item.workflow_version,
            target.state,
            target.phase
          )
        )

        validate_state_details!(work_item, target, envelope)

        evidence = %{
          reason: attrs[:reason],
          acceptance_review: attrs[:acceptance_review]
        }

        apply_change!(
          work_item,
          target,
          expected_version,
          "work_item.reopened",
          evidence,
          envelope
        )
      end,
      mode: :immediate
    )
    |> unwrap_change()
  end

  @spec version_precondition(String.t(), integer()) ::
          :ok | {:stale, term(), map()}
  def version_precondition(work_item_id, expected_version) do
    case get(work_item_id) do
      %WorkItem{version: ^expected_version} ->
        :ok

      %WorkItem{version: observed_version} ->
        stale(expected_version, observed_version)

      nil ->
        {:stale, :work_item_missing, %{work_item: %{expected: expected_version, observed: nil}}}
    end
  end

  @spec next_command(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def next_command(work_item_id, world_snapshot \\ %{}) do
    case get(work_item_id) do
      nil -> {:error, {:unknown_work_item, work_item_id}}
      work_item -> WorkKinds.next_command(work_item, world_snapshot)
    end
  end

  @spec render(WorkItem.t()) :: map()
  def render(%WorkItem{} = work_item) do
    work_item = preload(work_item)

    %{
      work_item_id: work_item.work_item_id,
      mission_id: work_item.mission.mission_id,
      parent_work_item_id: work_item.parent && work_item.parent.work_item_id,
      kind: work_item.kind,
      workflow_version: work_item.workflow_version,
      objective: work_item.objective,
      acceptance_criteria: work_item.acceptance_criteria,
      state: work_item.state,
      phase: work_item.phase,
      priority: work_item.priority,
      policy_ref: work_item.policy_ref,
      source: work_item.source,
      external_key: work_item.external_key,
      version: work_item.version,
      active_attempt_id: work_item.active_attempt_id,
      active_operation_call_id: work_item.active_operation_call_id,
      waiting_condition: work_item.waiting_condition,
      blocked_reason: work_item.blocked_reason,
      outcome: work_item.outcome,
      completed_at: iso8601(work_item.completed_at),
      cancelled_at: iso8601(work_item.cancelled_at),
      inserted_at: iso8601(work_item.inserted_at),
      updated_at: iso8601(work_item.updated_at)
    }
  end

  @spec render_event(WorkEvent.t()) :: map()
  def render_event(%WorkEvent{} = event) do
    %{
      event_id: event.event_id,
      kind: event.kind,
      actor: event.actor,
      operation: event.operation,
      operation_call_id: event.operation_call_id,
      gate_id: event.gate_id,
      before: %{
        state: event.before_state,
        phase: event.before_phase,
        version: event.before_version
      },
      after: %{
        state: event.after_state,
        phase: event.after_phase,
        version: event.work_item_version
      },
      evidence: event.evidence,
      correlation_id: event.correlation_id,
      causation_id: event.causation_id,
      inserted_at: iso8601(event.inserted_at)
    }
  end

  @doc false
  def reconcile_call(call_id) do
    case Repo.get_by(WorkEvent, operation_call_id: call_id) do
      nil ->
        :retry

      event ->
        work_item = WorkItem |> Repo.get!(event.work_item_id) |> preload()

        {:ok, work_item, event}
    end
  end

  defp transition_target(work_item, attrs) do
    state = attrs[:state]

    %{
      state: state,
      phase: attrs[:phase],
      acceptance_criteria: work_item.acceptance_criteria,
      active_attempt_id: target_value(state, "active", attrs, :active_attempt_id, work_item),
      active_operation_call_id:
        target_value(state, "active", attrs, :active_operation_call_id, work_item),
      waiting_condition: target_value(state, "waiting", attrs, :waiting_condition, work_item),
      blocked_reason: target_value(state, "blocked", attrs, :blocked_reason, work_item),
      outcome: target_value(state, @terminal, attrs, :outcome, work_item)
    }
  end

  defp target_value(state, required_state, attrs, field, work_item)
       when is_binary(required_state) do
    if state == required_state, do: Map.get(attrs, field, Map.get(work_item, field)), else: nil
  end

  defp target_value(state, required_states, attrs, field, work_item) do
    if state in required_states, do: Map.get(attrs, field, Map.get(work_item, field)), else: nil
  end

  defp validate_generic_transition!(work_item, target) do
    cond do
      work_item.state in @terminal ->
        Repo.rollback(:terminal_work_requires_reopen)

      target.state not in @states ->
        Repo.rollback({:invalid_state, target.state})

      target.state == work_item.state and target.phase == work_item.phase ->
        Repo.rollback(:work_item_transition_noop)

      target.state == work_item.state ->
        :ok

      target.state in Map.fetch!(@transitions, work_item.state) ->
        :ok

      true ->
        Repo.rollback({:illegal_state_transition, %{from: work_item.state, to: target.state}})
    end
  end

  defp validate_state_details!(work_item, %{state: "active"} = target, envelope) do
    references =
      Enum.count(
        [target.active_attempt_id, target.active_operation_call_id],
        &nonempty_binary?/1
      )

    rollback_unless(references == 1, :active_reference_required)

    if target.active_operation_call_id do
      validate_operation_call_reference!(work_item, target.active_operation_call_id, envelope)
    end
  end

  defp validate_state_details!(_work_item, %{state: "waiting"} = target, _envelope),
    do: rollback_unless(structured?(target.waiting_condition), :waiting_condition_required)

  defp validate_state_details!(_work_item, %{state: "blocked"} = target, _envelope),
    do: rollback_unless(structured?(target.blocked_reason), :blocked_reason_required)

  defp validate_state_details!(_work_item, %{state: state} = target, _envelope)
       when state in @terminal,
       do: rollback_unless(structured?(target.outcome), :terminal_outcome_required)

  defp validate_state_details!(_work_item, _target, _envelope), do: :ok

  defp validate_operation_call_reference!(work_item, call_id, envelope) do
    call = Repo.get_by(OperationCall, call_id: call_id)
    work_item_id = work_item.work_item_id

    valid? =
      call_id != envelope.call_id and
        match?(
          %OperationCall{
            work_item_id: ^work_item_id,
            status: status
          }
          when status in @active_call_statuses,
          call
        )

    rollback_unless(valid?, {:invalid_active_operation_call, call_id})
  end

  defp apply_change!(
         work_item,
         target,
         expected_version,
         event_kind,
         evidence,
         envelope
       ) do
    now = DateTime.utc_now()
    next_version = expected_version + 1

    updates = [
      state: target.state,
      phase: target.phase,
      acceptance_criteria: target.acceptance_criteria,
      active_attempt_id: target.active_attempt_id,
      active_operation_call_id: target.active_operation_call_id,
      waiting_condition: target.waiting_condition,
      blocked_reason: target.blocked_reason,
      outcome: target.outcome,
      completed_at: terminal_timestamp(target.state, "completed", now),
      cancelled_at: terminal_timestamp(target.state, "cancelled", now),
      version: next_version,
      updated_at: now
    ]

    {updated_count, _rows} =
      Repo.update_all(
        from(item in WorkItem,
          where: item.id == ^work_item.id and item.version == ^expected_version
        ),
        set: updates
      )

    if updated_count == 0 do
      observed = Repo.get!(WorkItem, work_item.id)
      Repo.rollback(stale_tuple(expected_version, observed.version))
    end

    updated = WorkItem |> Repo.get!(work_item.id) |> preload()
    event = append_event!(updated, work_item, event_kind, evidence, envelope)
    {updated, event}
  end

  defp append_event!(work_item, before, event_kind, evidence, envelope) do
    attrs = %{
      event_id: Ecto.UUID.generate(),
      work_item_id: work_item.id,
      mission_id: work_item.mission_id,
      kind: event_kind,
      actor: normalize(envelope.actor),
      operation: envelope.operation,
      operation_call_id: envelope.call_id,
      before_state: before && before.state,
      before_phase: before && before.phase,
      after_state: work_item.state,
      after_phase: work_item.phase,
      before_version: before && before.version,
      work_item_version: work_item.version,
      evidence: normalize(evidence || %{}),
      correlation_id: envelope.correlation_id,
      causation_id: envelope.causation_id
    }

    attrs
    |> WorkEvent.create_changeset()
    |> Repo.insert!()
  end

  defp active_mission!(mission_id) do
    case Missions.get(mission_id) do
      %Mission{status: "active"} = mission -> mission
      %Mission{status: "archived"} -> Repo.rollback(:mission_archived)
      nil -> Repo.rollback({:unknown_mission, mission_id})
    end
  end

  defp parent!(nil, _mission), do: nil

  defp parent!(parent_work_item_id, mission) do
    case get(parent_work_item_id) do
      %WorkItem{mission_id: mission_id} = parent when mission_id == mission.id ->
        parent

      %WorkItem{} ->
        Repo.rollback(:parent_mission_mismatch)

      nil ->
        Repo.rollback({:unknown_parent_work_item, parent_work_item_id})
    end
  end

  defp work_item!(work_item_id) do
    case get(work_item_id) do
      nil -> Repo.rollback({:unknown_work_item, work_item_id})
      work_item -> work_item
    end
  end

  defp ensure_version!(work_item, expected_version) do
    if work_item.version != expected_version do
      Repo.rollback(stale_tuple(expected_version, work_item.version))
    end
  end

  defp handle_create_error!(changeset, source, external_key) do
    if unique_source_key?(changeset) do
      {:existing, get_by_source(source, external_key), nil}
    else
      Repo.rollback(changeset)
    end
  end

  defp unique_source_key?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        options[:constraint] == :unique and
          options[:constraint_name] == "work_items_source_external_key_index"
    end)
  end

  defp stale(expected, observed),
    do: {:stale, :work_item_version_changed, stale_observation(expected, observed)}

  defp stale_tuple(expected, observed),
    do: {:stale, :work_item_version_changed, stale_observation(expected, observed)}

  defp stale_observation(expected, observed),
    do: %{work_item: %{expected: expected, observed: observed}}

  defp terminal_timestamp(state, state, now), do: now
  defp terminal_timestamp(_state, _terminal, _now), do: nil

  defp structured?(value), do: is_map(value) and map_size(value) > 0
  defp nonempty_binary?(value), do: is_binary(value) and value != ""

  defp rollback_unless(true, _reason), do: :ok
  defp rollback_unless(false, reason), do: Repo.rollback(reason)

  defp rollback_unless_ok(:ok), do: :ok
  defp rollback_unless_ok({:error, reason}), do: Repo.rollback(reason)

  defp unwrap_create({:ok, {:created, work_item, event}}),
    do: {:ok, :created, work_item, event}

  defp unwrap_create({:ok, {:existing, work_item, nil}}),
    do: {:ok, :existing, work_item, nil}

  defp unwrap_create({:error, reason}), do: {:error, reason}

  defp unwrap_change({:ok, {work_item, event}}), do: {:ok, work_item, event}
  defp unwrap_change({:error, reason}), do: {:error, reason}

  defp preload(nil), do: nil
  defp preload(work_item), do: Repo.preload(work_item, [:mission, :parent])

  defp atomize(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) -> {String.to_existing_atom(key), value}
      pair -> pair
    end)
  end

  defp normalize(nil), do: nil
  defp normalize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp normalize(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), normalize(item)} end)
  end

  defp normalize(value), do: inspect(value)
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
