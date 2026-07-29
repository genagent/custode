defmodule Custode.WorkGates do
  @moduledoc """
  Durable, stale-aware decisions over exact work-scoped command previews.

  These gates deliberately live beside the legacy agent gates. They only
  dispatch through the operation spine and do not change any transport entry
  point.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Attempt,
    Feed,
    OperationCalls,
    OperationDefinition,
    OperationDispatcher,
    OperationEnvelope,
    OperationRegistry,
    Repo,
    WorkEvent,
    WorkGate,
    WorkItem,
    WorkItems
  }

  @type actor :: OperationEnvelope.actor()
  @terminal ~w(approved rejected stale cancelled superseded)

  @spec get(String.t()) :: WorkGate.t() | nil
  def get(gate_id), do: WorkGate |> Repo.get_by(gate_id: gate_id) |> preload()

  @spec list_open() :: [WorkGate.t()]
  def list_open do
    from(gate in WorkGate,
      where: gate.status == "open",
      order_by: [asc: gate.inserted_at, asc: gate.gate_id]
    )
    |> Repo.all()
    |> preload()
  end

  @spec list_for_work_item(String.t()) :: [WorkGate.t()]
  def list_for_work_item(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil ->
        []

      work_item ->
        from(gate in WorkGate,
          where: gate.work_item_id == ^work_item.id,
          order_by: [asc: gate.inserted_at, asc: gate.gate_id]
        )
        |> Repo.all()
        |> preload()
    end
  end

  @spec propose(map() | keyword(), keyword()) ::
          {:ok, WorkGate.t()} | {:error, term()}
  def propose(attrs, options) do
    attrs = atomize(attrs)
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    Repo.transaction(
      fn ->
        gate_id = required_binary!(attrs, :gate_id)
        work_item = work_item!(attrs[:work_item_id])
        ensure_active_mission!(work_item)
        ensure_waiting_for_gate!(work_item, gate_id)
        attempt = attempt!(attrs[:attempt_id], work_item)
        requester = principal!(options)
        policy_version = required_binary!(attrs, :policy_version)
        external = required_map!(attrs, :external_preconditions)
        operation_key = attrs[:operation_idempotency_key] || "gate:#{gate_id}:operation"
        arguments = required_map!(attrs, :arguments)
        ensure_operation_scope!(atomize(arguments), work_item)

        envelope =
          envelope!(
            Map.put(attrs, :arguments, arguments),
            work_item,
            attempt,
            requester,
            operation_key
          )

        inspection = inspect!(envelope, registry)
        ensure_subject!(attrs[:subject_kind], inspection.definition.name)
        ensure_operation_scope!(inspection.envelope.arguments, work_item)

        create_attrs = %{
          gate_id: gate_id,
          mission_id: work_item.mission_id,
          work_item_id: work_item.id,
          attempt_id: attempt && attempt.id,
          subject_kind: attrs[:subject_kind],
          operation: inspection.definition.name,
          arguments: json(inspection.envelope.arguments),
          preview: json(inspection.preview),
          requester: json(requester),
          status: "open",
          work_item_version: work_item.version,
          policy_version: policy_version,
          grant_decision: %{
            "decision" => "allowed",
            "requester_grant" => to_string(inspection.grant),
            "required_grants" =>
              inspection.definition.required_grants
              |> Enum.map(&to_string/1)
              |> Enum.sort()
          },
          external_preconditions: json(external),
          definition_fingerprint: OperationDefinition.fingerprint(inspection.definition),
          operation_idempotency_key: operation_key,
          correlation_id: attrs[:correlation_id],
          causation_id: attrs[:causation_id]
        }

        insert_gate!(create_attrs)
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  @spec approve(String.t(), map() | keyword(), keyword()) ::
          {:ok, WorkGate.t(), map()}
          | {:error, {:stale, map(), WorkGate.t()}}
          | {:error, {:operation_failed, term(), WorkGate.t()}}
          | {:error, term()}
  def approve(gate_id, current, options) do
    current = atomize(current)
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    Repo.transaction(
      fn ->
        gate = open_gate!(gate_id)
        resolver = principal!(options)

        case revalidate(gate, current, resolver, registry) do
          {:ok, inspection} ->
            approve_and_dispatch!(gate, inspection, resolver, registry)

          {:stale, changes} ->
            gate = resolve_stale!(gate, resolver, changes, "gate.approve")
            {:stale, changes, gate}
        end
      end,
      mode: :immediate
    )
    |> after_approval()
  end

  @spec reject(String.t(), map() | keyword(), keyword()) ::
          {:ok, WorkGate.t()} | {:error, term()}
  def reject(gate_id, reason, options) do
    Repo.transaction(
      fn ->
        gate = open_gate!(gate_id)
        resolver = principal!(options)
        authorize_resolution!(gate, resolver, options)
        reason = required_structured!(reason, :reason)

        gate =
          resolve!(
            gate,
            resolver,
            "rejected",
            %{"decision" => "rejected"},
            reason
          )

        append_outcome_event!(gate, resolver, "gate.rejected", "gate.reject", reason)
        {:rejected, gate}
      end,
      mode: :immediate
    )
    |> after_resolution()
  end

  @spec cancel(String.t(), map() | keyword(), keyword()) ::
          {:ok, WorkGate.t()} | {:error, term()}
  def cancel(gate_id, reason, options) do
    resolve_without_event(gate_id, "cancelled", reason, options)
  end

  @spec supersede(String.t(), String.t(), map() | keyword(), keyword()) ::
          {:ok, WorkGate.t()} | {:error, term()}
  def supersede(gate_id, replacement_gate_id, reason, options) do
    Repo.transaction(
      fn ->
        gate = open_gate!(gate_id)
        replacement = gate!(replacement_gate_id)

        if replacement.work_item_id != gate.work_item_id do
          Repo.rollback(:replacement_work_item_mismatch)
        end

        resolver = principal!(options)
        authorize_resolution!(gate, resolver, options)
        reason = required_structured!(reason, :reason)

        resolve!(
          gate,
          resolver,
          "superseded",
          %{"decision" => "superseded", "replacement_gate_id" => replacement.gate_id},
          reason
        )
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  @spec render(WorkGate.t()) :: map()
  def render(%WorkGate{} = gate) do
    gate = preload(gate)

    %{
      gate_id: gate.gate_id,
      mission_id: gate.mission.mission_id,
      work_item_id: gate.work_item.work_item_id,
      attempt_id: gate.attempt && gate.attempt.attempt_id,
      operation_call_id: gate.operation_call_id,
      subject_kind: gate.subject_kind,
      operation: gate.operation,
      arguments: gate.arguments,
      preview: gate.preview,
      requester: gate.requester,
      resolver: gate.resolver,
      status: gate.status,
      resolution: gate.resolution,
      reason: gate.reason,
      work_item_version: gate.work_item_version,
      policy_version: gate.policy_version,
      grant_decision: gate.grant_decision,
      external_preconditions: gate.external_preconditions,
      definition_fingerprint: gate.definition_fingerprint,
      operation_idempotency_key: gate.operation_idempotency_key,
      correlation_id: gate.correlation_id,
      causation_id: gate.causation_id,
      resolved_at: iso8601(gate.resolved_at),
      inserted_at: iso8601(gate.inserted_at),
      updated_at: iso8601(gate.updated_at)
    }
  end

  defp approve_and_dispatch!(gate, inspection, resolver, registry) do
    envelope = invocation_envelope(gate, resolver)
    result = OperationDispatcher.dispatch(envelope, registry)
    call = OperationCalls.get_for_invocation(inspection.definition, envelope)

    case result do
      {:ok, response} ->
        gate =
          resolve!(
            gate,
            resolver,
            "approved",
            %{"decision" => "approved", "operation_status" => to_string(response.status)},
            nil,
            call && call.call_id
          )

        {:approved, gate, response}

      {:error, {:denied, reason}} ->
        changes = %{"grant_decision" => %{"observed" => json(reason)}}
        gate = resolve_stale!(gate, resolver, changes, "gate.approve")
        {:stale, changes, gate}

      {:error, {:stale, reason}} ->
        changes = %{"operation_precondition" => %{"observed" => json(reason)}}
        gate = resolve_stale!(gate, resolver, changes, "gate.approve")
        {:stale, changes, gate}

      {:error, reason} ->
        gate =
          resolve!(
            gate,
            resolver,
            "approved",
            %{"decision" => "approved", "operation_status" => "failed"},
            %{"operation_error" => json(reason)},
            call && call.call_id
          )

        {:operation_failed, reason, gate}
    end
  end

  defp revalidate(gate, current, resolver, registry) do
    work_item = WorkItems.get(gate.work_item.work_item_id)
    changes = snapshot_changes(gate, work_item, current, registry)

    inspection =
      if changes == %{} do
        inspect_current(gate, work_item, resolver, registry)
      else
        {:error, :snapshot_changed}
      end

    changes = inspection_changes(gate, inspection, changes)

    if changes == %{} do
      {:ok, elem(inspection, 1)}
    else
      {:stale, changes}
    end
  end

  defp snapshot_changes(gate, work_item, current, registry) do
    %{}
    |> changed(
      "work_item_version",
      gate.work_item_version,
      work_item && work_item.version
    )
    |> changed("policy_version", gate.policy_version, current[:policy_version])
    |> changed(
      "external_preconditions",
      gate.external_preconditions,
      json(current[:external_preconditions])
    )
    |> changed(
      "definition_fingerprint",
      gate.definition_fingerprint,
      current_fingerprint(registry, gate.operation)
    )
    |> maybe_changed_waiting(gate, work_item)
  end

  defp inspection_changes(_gate, {:error, :snapshot_changed}, changes), do: changes

  defp inspection_changes(gate, {:ok, inspection}, changes) do
    changes
    |> changed("preview", gate.preview, json(inspection.preview))
    |> changed(
      "grant_decision",
      %{
        "decision" => "allowed",
        "required_grants" => gate.grant_decision["required_grants"]
      },
      %{
        "decision" => "allowed",
        "required_grants" =>
          inspection.definition.required_grants
          |> Enum.map(&to_string/1)
          |> Enum.sort()
      }
    )
  end

  defp inspection_changes(_gate, {:error, {:denied, reason}}, changes) do
    Map.put(changes, "grant_decision", %{
      "expected" => "allowed",
      "observed" => json(reason)
    })
  end

  defp inspection_changes(_gate, {:error, {:stale, reason, observed}}, changes) do
    Map.put(changes, "operation_precondition", %{
      "reason" => json(reason),
      "observed" => json(observed)
    })
  end

  defp inspection_changes(_gate, {:error, reason}, changes) do
    Map.put(changes, "operation_inspection", %{"observed" => json(reason)})
  end

  defp inspect_current(gate, work_item, resolver, registry) do
    gate
    |> invocation_envelope(resolver)
    |> Map.put(:mission_id, work_item.mission.mission_id)
    |> OperationDispatcher.inspect_invocation(registry)
  end

  defp current_fingerprint(registry, operation) do
    case OperationRegistry.fetch(registry, operation) do
      {:ok, definition} -> OperationDefinition.fingerprint(definition)
      :error -> nil
    end
  end

  defp maybe_changed_waiting(changes, _gate, nil), do: changes

  defp maybe_changed_waiting(changes, gate, work_item) do
    observed = %{
      "state" => work_item.state,
      "condition" => json(work_item.waiting_condition)
    }

    expected = %{
      "state" => "waiting",
      "condition" => %{"kind" => "gate", "gate_id" => gate.gate_id}
    }

    if waiting_for_gate?(work_item, gate.gate_id) do
      changes
    else
      Map.put(changes, "waiting_condition", %{
        "expected" => expected,
        "observed" => observed
      })
    end
  end

  defp changed(changes, _name, expected, observed) when expected == observed, do: changes

  defp changed(changes, name, expected, observed) do
    Map.put(changes, name, %{"expected" => json(expected), "observed" => json(observed)})
  end

  defp resolve_stale!(gate, resolver, changes, operation) do
    reason = %{"changed_preconditions" => changes}

    gate =
      resolve!(
        gate,
        resolver,
        "stale",
        %{"decision" => "stale", "changed_preconditions" => Map.keys(changes) |> Enum.sort()},
        reason
      )

    append_outcome_event!(gate, resolver, "gate.stale", operation, reason)
    gate
  end

  defp resolve_without_event(gate_id, status, reason, options) when status in @terminal do
    Repo.transaction(
      fn ->
        gate = open_gate!(gate_id)
        resolver = principal!(options)
        authorize_resolution!(gate, resolver, options)
        reason = required_structured!(reason, :reason)

        resolve!(
          gate,
          resolver,
          status,
          %{"decision" => status},
          reason
        )
      end,
      mode: :immediate
    )
    |> unwrap()
  end

  defp resolve!(gate, resolver, status, resolution, reason, operation_call_id \\ nil) do
    gate
    |> WorkGate.resolve_changeset(%{
      operation_call_id: operation_call_id,
      resolver: json(resolver),
      status: status,
      resolution: resolution,
      reason: reason,
      resolved_at: DateTime.utc_now()
    })
    |> Repo.update!()
    |> preload()
  end

  defp append_outcome_event!(gate, resolver, kind, operation, reason) do
    work_item = Repo.get!(WorkItem, gate.work_item_id)

    %{
      event_id: Ecto.UUID.generate(),
      work_item_id: work_item.id,
      mission_id: work_item.mission_id,
      gate_id: gate.gate_id,
      kind: kind,
      actor: json(resolver.actor),
      operation: operation,
      before_state: work_item.state,
      before_phase: work_item.phase,
      after_state: work_item.state,
      after_phase: work_item.phase,
      before_version: work_item.version,
      work_item_version: work_item.version,
      evidence: %{
        "gate_id" => gate.gate_id,
        "preview" => gate.preview,
        "reason" => reason
      },
      correlation_id: gate.correlation_id,
      causation_id: gate.causation_id
    }
    |> WorkEvent.create_changeset()
    |> Repo.insert!()
  end

  defp insert_gate!(attrs) do
    case Repo.insert(WorkGate.create_changeset(attrs)) do
      {:ok, gate} ->
        preload(gate)

      {:error, changeset} ->
        resolve_insert_error!(changeset, attrs)
    end
  end

  defp resolve_insert_error!(changeset, attrs) do
    unless unique_gate_id?(changeset), do: Repo.rollback(changeset)

    existing = gate!(attrs.gate_id)

    if same_proposal?(existing, attrs),
      do: existing,
      else: Repo.rollback({:gate_id_conflict, attrs.gate_id})
  end

  defp same_proposal?(gate, attrs) do
    Enum.all?(
      [
        :mission_id,
        :work_item_id,
        :attempt_id,
        :subject_kind,
        :operation,
        :arguments,
        :preview,
        :requester,
        :work_item_version,
        :policy_version,
        :grant_decision,
        :external_preconditions,
        :definition_fingerprint,
        :operation_idempotency_key,
        :correlation_id,
        :causation_id
      ],
      &(Map.get(gate, &1) == Map.get(attrs, &1))
    )
  end

  defp unique_gate_id?(changeset) do
    Enum.any?(changeset.errors, fn
      {:gate_id, {_message, options}} -> options[:constraint] == :unique
      _other -> false
    end)
  end

  defp envelope!(attrs, work_item, attempt, principal, operation_key) do
    %{
      operation: attrs[:operation],
      arguments: required_map!(attrs, :arguments),
      actor: principal.actor,
      transport: principal.transport,
      mission_id: work_item.mission.mission_id,
      work_item_id: work_item.work_item_id,
      attempt_id: attempt && attempt.attempt_id,
      expected_versions: %{work_item: work_item.version},
      idempotency_key: operation_key,
      correlation_id: attrs[:correlation_id],
      causation_id: attrs[:causation_id]
    }
    |> OperationEnvelope.new()
    |> case do
      {:ok, envelope} -> envelope
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp invocation_envelope(gate, principal) do
    %OperationEnvelope{
      operation: gate.operation,
      arguments: atomize(gate.arguments),
      actor: principal.actor,
      transport: principal.transport,
      mission_id: gate.mission.mission_id,
      work_item_id: gate.work_item.work_item_id,
      attempt_id: gate.attempt && gate.attempt.attempt_id,
      expected_versions: %{work_item: gate.work_item_version},
      idempotency_key: gate.operation_idempotency_key,
      correlation_id: gate.correlation_id,
      causation_id: gate.causation_id
    }
  end

  defp inspect!(envelope, registry) do
    case OperationDispatcher.inspect_invocation(envelope, registry) do
      {:ok, inspection} -> inspection
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp authorize_resolution!(gate, resolver, options) do
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    case gate
         |> invocation_envelope(resolver)
         |> OperationDispatcher.authorize_invocation(registry) do
      {:ok, _authorization} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp ensure_subject!("transition", "work.transition"), do: :ok

  defp ensure_subject!("transition", operation),
    do: Repo.rollback({:invalid_transition, operation})

  defp ensure_subject!("operation_call", _operation), do: :ok
  defp ensure_subject!(subject, _operation), do: Repo.rollback({:invalid_subject_kind, subject})

  defp ensure_operation_scope!(arguments, work_item) do
    with :ok <- ensure_argument_match(arguments, :work_item_id, work_item.work_item_id),
         :ok <- ensure_argument_match(arguments, :expected_version, work_item.version) do
      :ok
    else
      {:error, mismatch} -> Repo.rollback({:operation_scope_mismatch, mismatch})
    end
  end

  defp ensure_argument_match(arguments, field, expected) do
    case Map.fetch(arguments, field) do
      {:ok, ^expected} -> :ok
      {:ok, observed} -> {:error, %{field: field, expected: expected, observed: observed}}
      :error -> :ok
    end
  end

  defp work_item!(work_item_id) do
    case WorkItems.get(work_item_id) do
      nil -> Repo.rollback({:unknown_work_item, work_item_id})
      work_item -> work_item
    end
  end

  defp ensure_active_mission!(%WorkItem{mission: %{status: "active"}}), do: :ok

  defp ensure_active_mission!(%WorkItem{mission: %{status: "archived"}}),
    do: Repo.rollback(:mission_archived)

  defp ensure_waiting_for_gate!(work_item, gate_id) do
    unless waiting_for_gate?(work_item, gate_id),
      do: Repo.rollback({:work_item_not_waiting_for_gate, gate_id})
  end

  defp waiting_for_gate?(%WorkItem{state: "waiting", waiting_condition: condition}, gate_id) do
    condition = json(condition)
    condition["kind"] == "gate" and condition["gate_id"] == gate_id
  end

  defp waiting_for_gate?(_work_item, _gate_id), do: false

  defp attempt!(nil, _work_item), do: nil

  defp attempt!(attempt_id, work_item) do
    case Repo.get_by(Attempt, attempt_id: attempt_id) do
      %Attempt{work_item_id: work_item_id} = attempt when work_item_id == work_item.id ->
        attempt

      %Attempt{} ->
        Repo.rollback(:attempt_work_item_mismatch)

      nil ->
        Repo.rollback({:unknown_attempt, attempt_id})
    end
  end

  defp gate!(gate_id) do
    case get(gate_id) do
      nil -> Repo.rollback({:unknown_gate, gate_id})
      gate -> gate
    end
  end

  defp open_gate!(gate_id) do
    case gate!(gate_id) do
      %WorkGate{status: "open"} = gate -> gate
      %WorkGate{status: status} -> Repo.rollback({:gate_already_resolved, status})
    end
  end

  defp principal!(options) do
    actor = Keyword.fetch!(options, :actor)
    transport = Keyword.fetch!(options, :transport)

    case OperationEnvelope.new(%{
           operation: "gate.validate",
           arguments: %{},
           actor: actor,
           transport: transport
         }) do
      {:ok, envelope} -> %{actor: envelope.actor, transport: envelope.transport}
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp required_binary!(attrs, field) do
    case attrs[field] do
      value when is_binary(value) and value != "" -> value
      _missing -> Repo.rollback({:required, field})
    end
  end

  defp required_map!(attrs, field) do
    case attrs[field] do
      value when is_map(value) -> value
      _missing -> Repo.rollback({:required, field})
    end
  end

  defp required_structured!(value, _field) when is_map(value) and map_size(value) > 0,
    do: json(value)

  defp required_structured!(value, field) when is_list(value) do
    value
    |> Map.new()
    |> required_structured!(field)
  rescue
    ArgumentError -> Repo.rollback({:required, field})
  end

  defp required_structured!(_value, field), do: Repo.rollback({:required, field})

  defp after_approval({:ok, {:approved, gate, response}}), do: {:ok, gate, response}

  defp after_approval({:ok, {:stale, changes, gate}}) do
    record_outcome(gate, "work_gate_stale", changes)
    {:error, {:stale, changes, gate}}
  end

  defp after_approval({:ok, {:operation_failed, reason, gate}}),
    do: {:error, {:operation_failed, reason, gate}}

  defp after_approval({:error, reason}), do: {:error, reason}

  defp after_resolution({:ok, {:rejected, gate}}) do
    record_outcome(gate, "work_gate_rejected", gate.reason)
    {:ok, gate}
  end

  defp after_resolution({:error, reason}), do: {:error, reason}

  defp record_outcome(gate, event, details) do
    Feed.record(%{
      event: event,
      agent: gate.resolver["actor"]["id"],
      gate_id: gate.gate_id,
      work_item_id: gate.work_item.work_item_id,
      details: details,
      summary: "#{event}: #{gate.gate_id}"
    })
  end

  defp unwrap({:ok, value}), do: {:ok, value}
  defp unwrap({:error, reason}), do: {:error, reason}

  defp preload(nil), do: nil

  defp preload(gates) when is_list(gates),
    do: Repo.preload(gates, [:mission, :work_item, :attempt])

  defp preload(gate), do: Repo.preload(gate, [:mission, :work_item, :attempt])

  defp atomize(map) when is_map(map) do
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

  defp atomize(value), do: Map.new(value)

  defp json(nil), do: nil
  defp json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  defp json(value) when is_list(value), do: Enum.map(value, &json/1)

  defp json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)
  end

  defp json(value), do: inspect(value)

  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
