defmodule Custode.WorkProcess do
  @moduledoc """
  Deterministic WorkItem process manager and restart-safe command delivery.

  A next action is claimed by one append-only WorkEvent for a WorkItem version.
  Effectful decisions are delivered through `WorkCommandJob` with only the
  decision ID, WorkItem ID, and expected version. Reconciliation can therefore
  recreate missing physical delivery without creating a new Attempt,
  OperationCall, Gate, or logical action.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Attempt,
    Attempts,
    OperationCall,
    OperationDefinition,
    OperationDispatcher,
    OperationEnvelope,
    OperationRegistry,
    Repo,
    WorkCommandJob,
    WorkEvent,
    WorkGates,
    WorkItem,
    WorkItems,
    WorkKinds
  }

  alias Custode.AttemptPool.Refusal
  alias Custode.Operations.WorkItems, as: WorkOperations
  alias Custode.WorkProcess.Decision

  @live_job_states ~w(available scheduled executing retryable)
  @active_call_states ~w(proposed waiting running)

  @type result ::
          {:ok,
           %{status: atom(), decision: Decision.t(), event: WorkEvent.t() | nil, job: term()}}
          | {:error, term()}

  @spec reconcile(String.t(), pos_integer(), map(), keyword()) :: result()
  def reconcile(work_item_id, expected_version, world_snapshot \\ %{}, options \\ [])
      when is_binary(work_item_id) and is_integer(expected_version) and is_map(world_snapshot) do
    case claim_for_version(work_item_id, expected_version) do
      %WorkEvent{} = event ->
        deliver_existing(event, options)

      nil ->
        reconcile_unclaimed(work_item_id, expected_version, world_snapshot, options)
    end
  end

  @doc """
  Execute one already-claimed command.

  The worker passes only stable IDs. Tests and compatibility drivers may pass a
  registry explicitly, but no provider callback or conversation state crosses
  this boundary.
  """
  @spec perform(String.t(), String.t(), pos_integer(), integer() | nil, keyword()) ::
          :ok | {:discard, term()} | {:snooze, pos_integer()} | {:error, term()}
  def perform(decision_id, work_item_id, expected_version, oban_job_id, options \\ []) do
    with %WorkEvent{} = event <- Repo.get_by(WorkEvent, event_id: decision_id),
         :ok <- verify_command(event, work_item_id, expected_version),
         false <- completed?(event.event_id),
         work_item when not is_nil(work_item) <- WorkItems.get(work_item_id),
         {:ok, decision} <- Decision.restore(event.evidence["decision"], work_item) do
      finish_execution(execute(decision, event, oban_job_id, options), event)
    else
      nil -> {:discard, :unknown_process_decision}
      true -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:discard, other}
    end
  end

  @doc """
  Finish a logical Attempt without applying its proposed WorkItem transition.

  A later reconciliation reads the durable outcome, asks the work kind for the
  next decision, and validates any proposal through the normal transition
  operation.
  """
  @spec record_attempt_result(String.t(), map() | keyword()) ::
          {:ok, Attempt.t()} | {:error, term()}
  def record_attempt_result(attempt_id, attrs), do: Attempts.finish(attempt_id, attrs)

  defp reconcile_unclaimed(work_item_id, expected_version, snapshot, options) do
    with %WorkItem{} = work_item <- WorkItems.get(work_item_id),
         :ok <- expected_version(work_item, expected_version),
         {:ok, command} <- next_command(work_item, snapshot, options),
         {:ok, decision} <- prepare_decision(command, work_item, snapshot, options) do
      if Decision.effectful?(decision) do
        claim_and_deliver(work_item, expected_version, decision, options)
      else
        {:ok, %{status: :idle, decision: decision, event: nil, job: nil}}
      end
    else
      nil -> {:error, {:unknown_work_item, work_item_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_command(%WorkItem{state: "waiting"} = work_item, snapshot, _options) do
    case wake_transition(work_item, snapshot) do
      {:ok, transition} -> {:ok, %{action: :transition, transition: transition}}
      :waiting -> WorkKinds.next_command(work_item, snapshot)
      {:error, reason} -> {:error, reason}
    end
  end

  defp next_command(%WorkItem{state: "active"} = work_item, snapshot, options) do
    active_command(work_item, snapshot, options)
  end

  defp next_command(work_item, snapshot, _options),
    do: WorkKinds.next_command(work_item, snapshot)

  defp active_command(%WorkItem{active_attempt_id: attempt_id} = work_item, snapshot, options)
       when is_binary(attempt_id) do
    case Attempts.get(attempt_id) do
      nil ->
        block_command(work_item, "execution_missing", %{attempt_id: attempt_id})

      %Attempt{state: state} = attempt
      when state in ~w(succeeded failed partial blocked cancelled) ->
        attempt_result_command(work_item, attempt)

      %Attempt{} = attempt ->
        active_attempt_command(work_item, attempt, snapshot, options)
    end
  end

  defp active_command(
         %WorkItem{active_operation_call_id: call_id} = work_item,
         snapshot,
         _options
       )
       when is_binary(call_id) do
    case Repo.get_by(OperationCall, call_id: call_id) do
      nil ->
        block_command(work_item, "execution_missing", %{operation_call_id: call_id})

      %OperationCall{status: status} when status in @active_call_states ->
        if call_id in string_list(snapshot, :live_operation_call_ids) do
          {:ok, %{action: :observe, operation_call_id: call_id}}
        else
          block_command(work_item, "execution_missing", %{operation_call_id: call_id})
        end

      %OperationCall{} = call ->
        operation_result_command(work_item, call, snapshot)
    end
  end

  defp active_command(work_item, _snapshot, _options),
    do: block_command(work_item, "execution_missing", %{})

  defp active_attempt_command(work_item, attempt, snapshot, options) do
    cond do
      attempt.attempt_id in string_list(snapshot, :live_attempt_ids) ->
        {:ok, %{action: :observe, attempt_id: attempt.attempt_id}}

      attempt.state == "queued" ->
        redeliver_attempt_claim(work_item, attempt, options)

      live_job_for_attempt?(work_item.id, attempt.attempt_id) ->
        {:ok, %{action: :observe, attempt_id: attempt.attempt_id}}

      true ->
        block_command(work_item, "execution_missing", %{attempt_id: attempt.attempt_id})
    end
  end

  defp redeliver_attempt_claim(work_item, attempt, options) do
    case claim_for_attempt(work_item.id, attempt.attempt_id) do
      nil ->
        block_command(work_item, "execution_missing", %{attempt_id: attempt.attempt_id})

      claim ->
        observe_after_delivery(deliver_existing(claim, options), attempt.attempt_id)
    end
  end

  defp observe_after_delivery({:ok, _delivery}, attempt_id),
    do: {:ok, %{action: :observe, attempt_id: attempt_id}}

  defp observe_after_delivery({:error, reason}, _attempt_id), do: {:error, reason}

  defp attempt_result_command(work_item, attempt) do
    case proposal(attempt.outcome) do
      {:ok, transition} ->
        {:ok,
         %{
           action: :transition,
           transition: put_policy_evidence(transition, attempt_policy(attempt))
         }}

      :error ->
        block_command(work_item, "terminal_attempt_requires_policy", %{
          attempt_id: attempt.attempt_id,
          attempt_state: attempt.state
        })
    end
  end

  defp operation_result_command(work_item, call, snapshot) do
    transitions = value(snapshot, :operation_transitions) || %{}
    transition = value(transitions, call.call_id)

    if is_map(transition) do
      {:ok, %{action: :transition, transition: transition}}
    else
      block_command(work_item, "terminal_operation_requires_policy", %{
        operation_call_id: call.call_id,
        operation_status: call.status
      })
    end
  end

  defp block_command(work_item, code, details) do
    {:ok,
     %{
       action: :transition,
       transition: %{
         state: "blocked",
         phase: work_item.phase,
         blocked_reason: Map.put(details, :code, code),
         evidence: %{reconciler: %{code: code}}
       }
     }}
  end

  defp prepare_decision(%{action: action} = command, work_item, snapshot, _options)
       when action in [:dispatch_attempt, "dispatch_attempt"] do
    with {:ok, attempt} <- required_snapshot_map(snapshot, :attempt),
         command_kind when is_binary(command_kind) <- value(command, :kind) do
      attempt =
        attempt
        |> put(:attempt_id, value(attempt, :attempt_id) || Ecto.UUID.generate())
        |> put(:work_item_id, work_item.work_item_id)
        |> put(:expected_work_item_version, work_item.version)
        |> put(:command_kind, command_kind)

      transition = %{
        state: "active",
        phase: value(command, :phase),
        active_attempt_id: value(attempt, :attempt_id),
        evidence:
          %{
            process: %{action: "dispatch_attempt", kind: command_kind}
          }
          |> maybe_put(:work_policy, attempt_policy(attempt))
      }

      Decision.new(
        %{action: :dispatch_attempt, attempt: attempt, transition: transition},
        work_item
      )
    else
      nil -> {:error, {:invalid_process_decision, :attempt_kind}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepare_decision(%{action: action} = command, work_item, snapshot, options)
       when action in [:invoke_operation, "invoke_operation"] do
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    with {:ok, invocation} <- required_snapshot_map(snapshot, :operation),
         expected_name when is_binary(expected_name) <- value(command, :operation),
         ^expected_name <- value(invocation, :operation),
         {:ok, inspection} <- OperationDispatcher.inspect_invocation(invocation, registry) do
      operation =
        inspection.envelope
        |> Map.from_struct()
        |> Map.put(
          :definition_fingerprint,
          OperationDefinition.fingerprint(inspection.definition)
        )
        |> Map.put(:effect_preview, inspection.preview)

      Decision.new(
        %{
          action: :invoke_operation,
          operation: operation,
          transition: value(snapshot, :operation_transition)
        },
        work_item
      )
    else
      nil ->
        {:error, {:invalid_process_decision, :operation_name}}

      {:error, reason} ->
        {:error, reason}

      observed ->
        {:error,
         {:operation_mismatch, %{expected: value(command, :operation), observed: observed}}}
    end
  end

  defp prepare_decision(command, work_item, _snapshot, _options),
    do: Decision.new(command, work_item)

  defp claim_and_deliver(work_item, expected_version, decision, options) do
    case claim(work_item, expected_version, decision, options) do
      {:ok, event} -> deliver_existing(event, options)
      {:existing, event} -> deliver_existing(event, options)
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim(work_item, expected_version, decision, options) do
    result =
      Repo.transaction(
        fn ->
          current = Repo.get!(WorkItem, work_item.id)

          if current.version != expected_version do
            Repo.rollback(stale(current, expected_version))
          end

          attrs = %{
            event_id: Ecto.UUID.generate(),
            work_item_id: current.id,
            mission_id: current.mission_id,
            kind: "work.next_action.claimed",
            actor: %{"kind" => "system", "id" => "work-process"},
            operation: "work.process.decide",
            before_state: current.state,
            before_phase: current.phase,
            after_state: current.state,
            after_phase: current.phase,
            before_version: current.version,
            work_item_version: current.version,
            evidence: %{"decision" => json(Decision.render(decision))},
            correlation_id: options[:correlation_id],
            causation_id: options[:causation_id]
          }

          case attrs |> WorkEvent.create_changeset() |> Repo.insert() do
            {:ok, event} ->
              materialize_claim!(decision)
              event

            {:error, changeset} ->
              Repo.rollback({:claim_failed, changeset})
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, event} ->
        {:ok, event}

      {:error, {:claim_failed, changeset}} ->
        if unique_claim?(changeset) do
          {:existing, claim_for_version(work_item.work_item_id, expected_version)}
        else
          {:error, {:claim_failed, changeset}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_existing(event, options) do
    work_item = WorkItems.get(event_work_item_id(event))

    with %WorkItem{} <- work_item,
         {:ok, decision} <- Decision.restore(event.evidence["decision"], work_item) do
      cond do
        not Decision.effectful?(decision) ->
          {:ok, %{status: :idle, decision: decision, event: event, job: nil}}

        completed?(event.event_id) ->
          {:ok, %{status: :completed, decision: decision, event: event, job: nil}}

        Keyword.get(options, :enqueue, true) == false ->
          {:ok, %{status: :claimed, decision: decision, event: event, job: nil}}

        true ->
          enqueue(event, decision, options)
      end
    else
      nil -> {:error, :claimed_work_item_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_claim!(%Decision{action: "dispatch_attempt", attempt: attrs}) do
    case Attempts.create(attrs) do
      {:ok, {_status, _attempt}} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp materialize_claim!(%Decision{}), do: :ok

  defp enqueue(event, decision, options) do
    args = %{
      "decision_id" => event.event_id,
      "work_item_id" => event_work_item_id(event),
      "expected_version" => event.work_item_version
    }

    enqueue_fun = Keyword.get(options, :enqueue_fun, &Oban.insert/1)

    result =
      Repo.transaction(
        fn -> enqueue_fun.(WorkCommandJob.new(args)) end,
        mode: :immediate
      )

    case result do
      {:ok, {:ok, job}} ->
        {:ok, %{status: :enqueued, decision: decision, event: event, job: job}}

      {:ok, {:error, reason}} ->
        {:error, {:enqueue_failed, reason, event}}

      {:error, reason} ->
        {:error, {:enqueue_failed, reason, event}}
    end
  end

  defp execute(%Decision{action: "dispatch_attempt"} = decision, event, job_id, options) do
    case admit_attempt(decision.attempt, options) do
      :ok ->
        activate_and_dispatch(decision, event, job_id, options)

      {:ok, _admission} ->
        activate_and_dispatch(decision, event, job_id, options)

      {:retry, %Refusal{} = refusal} ->
        {:retry, refusal}

      {kind, %Refusal{} = refusal} when kind in [:blocked, :cancelled] ->
        refuse_attempt(decision, event, refusal, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp execute(%Decision{action: "transition"} = decision, event, _job_id, options) do
    case transition(decision.transition, event, options) do
      {:ok, _response} -> :ok
      {:error, {:stale, reason}} -> {:terminal, {:stale, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute(%Decision{action: "invoke_operation"} = decision, event, _job_id, options) do
    registry = Keyword.get(options, :registry, OperationRegistry.default())

    with :ok <- definition_unchanged(decision.operation, registry),
         envelope <- restore_envelope(decision.operation, event) do
      case OperationDispatcher.dispatch(envelope, registry) do
        {:ok, _response} ->
          execute_optional_transition(decision.transition, event, options)

        {:error, {:stale, reason}} ->
          {:terminal, {:stale, reason}}

        {:error, reason} ->
          block_failed_operation(event, reason, options)
      end
    end
  end

  defp execute(%Decision{action: "open_gate", gate: gate}, _event, _job_id, options) do
    requester = value(gate, :requester) || %{}

    resolve_options = [
      actor: restore_actor(value(requester, :actor)),
      transport: existing_atom(value(requester, :transport)),
      registry: Keyword.get(options, :registry, OperationRegistry.default())
    ]

    case WorkGates.propose(value(gate, :attrs) || gate, resolve_options) do
      {:ok, _gate} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp transition(transition, event, _options) do
    work_item_id = event_work_item_id(event)
    attrs = transition |> atomize() |> Map.put(:expected_version, event.work_item_version)
    work_policy = transition |> value(:evidence) |> value(:work_policy)

    WorkOperations.Transition.dispatch(
      work_item_id,
      attrs,
      actor: %{kind: :system, id: "work-process"},
      transport: :worker,
      idempotency_key: "work-process:#{event.event_id}:transition",
      work_policy: work_policy,
      correlation_id: event.correlation_id,
      causation_id: event.event_id
    )
  end

  defp optional_transition(nil, _event, _options), do: :ok

  defp optional_transition(transition, event, options) do
    case transition(transition, event, options) do
      {:ok, _response} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_optional_transition(transition, event, options) do
    case optional_transition(transition, event, options) do
      :ok -> :ok
      {:error, {:stale, reason}} -> {:terminal, {:stale, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_execution(:ok, event) do
    case append_completion(event, %{"status" => "succeeded"}) do
      {:ok, _completion} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish_execution({:terminal, {:stale, reason}}, event) do
    case append_completion(event, %{"status" => "stale", "reason" => json(reason)}) do
      {:ok, _completion} -> {:discard, {:stale, reason}}
      {:error, error} -> {:error, error}
    end
  end

  defp finish_execution({:terminal, {:operation_failed, reason}}, event) do
    outcome = %{"status" => "failed", "reason" => json(reason)}

    case append_completion(event, outcome) do
      {:ok, _completion} -> {:discard, {:operation_failed, reason}}
      {:error, error} -> {:error, error}
    end
  end

  defp finish_execution({:terminal, {:attempt_dispatch_refused, refusal}}, event) do
    outcome = %{
      "status" => Atom.to_string(refusal.kind),
      "worker_pool" => json(Refusal.render(refusal))
    }

    case append_completion(event, outcome) do
      {:ok, _completion} -> {:discard, {:attempt_dispatch_refused, refusal.code}}
      {:error, error} -> {:error, error}
    end
  end

  defp finish_execution({:retry, %Refusal{} = refusal}, _event) do
    seconds =
      refusal.retry_after_ms
      |> Kernel.||(1_000)
      |> then(&max(div(&1 + 999, 1_000), 1))

    {:snooze, seconds}
  end

  defp finish_execution({:error, reason}, _event), do: {:error, reason}

  defp cancel_stale_attempt(attempt, reason) do
    Attempts.finish(value(attempt, :attempt_id), %{
      state: "cancelled",
      usage: %{},
      outcome: %{kind: "stale_before_dispatch", reason: json(reason)}
    })
  end

  defp activate_attempt(decision, event, options) do
    case transition(decision.transition, event, options) do
      {:ok, _response} ->
        :ok

      {:error, {:stale, reason}} ->
        if attempt_already_active?(decision, event), do: :ok, else: {:stale, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp activate_and_dispatch(decision, event, job_id, options) do
    case activate_attempt(decision, event, options) do
      :ok ->
        case dispatch_attempt(decision.attempt, job_id, options) do
          :ok ->
            :ok

          {:retry, %Refusal{} = refusal} ->
            {:retry, refusal}

          {kind, %Refusal{} = refusal} when kind in [:blocked, :cancelled] ->
            refuse_attempt(decision, event, refusal, options)

          {:error, reason} ->
            {:error, reason}
        end

      {:stale, reason} ->
        cancel_stale_attempt(decision.attempt, reason)
        {:terminal, {:stale, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp attempt_already_active?(decision, event) do
    case WorkItems.get(event_work_item_id(event)) do
      %WorkItem{
        state: "active",
        phase: phase,
        active_attempt_id: attempt_id,
        version: version
      } ->
        phase == value(decision.transition, :phase) and
          attempt_id == value(decision.attempt, :attempt_id) and
          version == event.work_item_version + 1

      _other ->
        false
    end
  end

  defp dispatch_attempt(attempt, job_id, options) do
    case Keyword.get(options, :attempt_dispatcher) do
      nil ->
        case Attempts.start(value(attempt, :attempt_id), %{oban_job_id: job_id}) do
          {:ok, _attempt} -> :ok
          {:error, reason} -> {:error, reason}
        end

      dispatcher ->
        dispatcher.dispatch(attempt, job_id, options)
    end
  end

  defp admit_attempt(attempt, options) do
    case Keyword.get(options, :attempt_dispatcher) do
      nil ->
        :ok

      dispatcher ->
        if Code.ensure_loaded?(dispatcher) and function_exported?(dispatcher, :admit, 2),
          do: dispatcher.admit(attempt, options),
          else: :ok
    end
  end

  defp refuse_attempt(decision, event, refusal, options) do
    attempt_id = value(decision.attempt, :attempt_id)
    work_item = WorkItems.get(event_work_item_id(event))
    work_policy = attempt_policy(decision.attempt)
    proposal = refusal_proposal(work_item, attempt_id, refusal, work_policy)

    finish_attrs =
      %{
        state: if(refusal.kind == :cancelled, do: "cancelled", else: "blocked"),
        usage: %{},
        outcome: %{
          kind: "worker_pool_refusal",
          worker_pool: Refusal.render(refusal),
          proposal: proposal
        }
      }
      |> maybe_put_refusal_error(refusal)

    with {:ok, _attempt} <- Attempts.finish(attempt_id, finish_attrs),
         {:ok, _response} <- transition_refusal(work_item, proposal, event, options) do
      {:terminal, {:attempt_dispatch_refused, refusal}}
    else
      {:error, {:stale, reason}} -> {:terminal, {:stale, reason}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refusal_proposal(work_item, attempt_id, refusal, work_policy) do
    rendered = Refusal.render(refusal)

    %{
      state: "blocked",
      phase: work_item.phase,
      blocked_reason: %{
        code: "attempt_worker_unavailable",
        attempt_id: attempt_id,
        worker_pool: rendered
      },
      evidence:
        %{worker_pool: rendered}
        |> maybe_put(:work_policy, work_policy)
    }
  end

  defp maybe_put_refusal_error(attrs, %Refusal{kind: :cancelled}), do: attrs

  defp maybe_put_refusal_error(attrs, refusal) do
    attrs
    |> Map.put(:error_class, error_class(refusal.code))
    |> Map.put(:error_details, Refusal.render(refusal))
  end

  defp error_class("no_eligible_worker"), do: "capability_mismatch"
  defp error_class("workspace_lease_" <> _rest), do: "lease_unavailable"
  defp error_class("spend_limit_reached"), do: "limit"
  defp error_class("work_policy_" <> _rest), do: "policy_refusal"
  defp error_class(_code), do: "worker_unavailable"

  defp transition_refusal(work_item, proposal, event, _options) do
    WorkOperations.Transition.dispatch(
      work_item.work_item_id,
      Map.put(proposal, :expected_version, work_item.version),
      actor: %{kind: :system, id: "work-process"},
      transport: :worker,
      idempotency_key: "work-process:#{event.event_id}:worker-refusal",
      work_policy: proposal |> value(:evidence) |> value(:work_policy),
      correlation_id: event.correlation_id,
      causation_id: event.event_id
    )
  end

  defp block_failed_operation(event, reason, options) do
    failed_transition = %{
      state: "blocked",
      phase: event.after_phase,
      blocked_reason: %{code: "operation_failed", reason: json(reason)},
      evidence: %{reconciler: %{code: "operation_failed"}}
    }

    case transition(failed_transition, event, options) do
      {:ok, _response} -> {:terminal, {:operation_failed, reason}}
      {:error, {:stale, stale_reason}} -> {:terminal, {:stale, stale_reason}}
      {:error, transition_reason} -> {:error, transition_reason}
    end
  end

  defp append_completion(event, outcome) do
    work_item = WorkItems.get(event_work_item_id(event))

    attrs = %{
      event_id: Ecto.UUID.generate(),
      work_item_id: work_item.id,
      mission_id: work_item.mission_id,
      kind: "work.next_action.completed",
      actor: %{"kind" => "system", "id" => "work-process"},
      operation: "work.process.perform",
      before_state: event.after_state,
      before_phase: event.after_phase,
      after_state: work_item.state,
      after_phase: work_item.phase,
      before_version: event.work_item_version,
      work_item_version: work_item.version,
      evidence: Map.put(outcome, "decision_id", event.event_id),
      correlation_id: event.correlation_id,
      causation_id: event.event_id
    }

    case attrs |> WorkEvent.create_changeset() |> Repo.insert() do
      {:ok, completion} ->
        {:ok, completion}

      {:error, changeset} ->
        if unique_result?(changeset), do: {:ok, :existing}, else: {:error, changeset}
    end
  end

  defp wake_transition(work_item, snapshot) do
    wake = value(snapshot, :wake)

    cond do
      not is_map(wake) ->
        :waiting

      not wake_matches?(work_item.waiting_condition, wake, snapshot) ->
        {:error, :wake_condition_mismatch}

      not is_map(value(wake, :transition)) ->
        {:error, :wake_transition_required}

      true ->
        {:ok, value(wake, :transition)}
    end
  end

  defp wake_matches?(condition, wake, snapshot) do
    wake_matches_kind?(value(condition, :kind), condition, wake, snapshot)
  end

  defp wake_matches_kind?("external_event", condition, wake, _snapshot) do
    value(wake, :kind) == "external_event" and
      value(wake, :name) == value(condition, :name)
  end

  defp wake_matches_kind?("timer", condition, wake, snapshot),
    do: value(wake, :kind) == "timer" and timer_due?(condition, snapshot)

  defp wake_matches_kind?("gate", condition, wake, _snapshot) do
    value(wake, :kind) == "gate" and
      value(wake, :gate_id) == value(condition, :gate_id) and
      value(wake, :resolution) in ~w(approved rejected stale cancelled superseded)
  end

  defp wake_matches_kind?("reconciler", _condition, wake, _snapshot),
    do: value(wake, :kind) == "reconciler" and structured?(value(wake, :evidence))

  defp wake_matches_kind?(_kind, _condition, _wake, _snapshot), do: false

  defp timer_due?(condition, snapshot) do
    with wake_at when is_binary(wake_at) <- value(condition, :wake_at),
         {:ok, wake_datetime, _offset} <- DateTime.from_iso8601(wake_at),
         now when not is_nil(now) <- value(snapshot, :now),
         {:ok, now_datetime} <- datetime(now) do
      DateTime.compare(now_datetime, wake_datetime) in [:eq, :gt]
    else
      _other -> false
    end
  end

  defp datetime(%DateTime{} = datetime), do: {:ok, datetime}

  defp datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _error -> :error
    end
  end

  defp datetime(_value), do: :error

  defp proposal(outcome) when is_map(outcome) do
    case value(outcome, :proposal) do
      proposal when is_map(proposal) -> {:ok, proposal}
      _other -> :error
    end
  end

  defp proposal(_outcome), do: :error

  defp claim_for_version(work_item_id, version) do
    with %WorkItem{} = work_item <- WorkItems.get(work_item_id) do
      Repo.one(
        from(event in WorkEvent,
          where:
            event.work_item_id == ^work_item.id and
              event.work_item_version == ^version and
              event.kind == "work.next_action.claimed",
          limit: 1
        )
      )
    end
  end

  defp claim_for_attempt(work_item_id, attempt_id) do
    from(event in WorkEvent,
      where:
        event.work_item_id == ^work_item_id and
          event.kind == "work.next_action.claimed",
      order_by: [desc: event.inserted_at]
    )
    |> Repo.all()
    |> Enum.find(&(get_in(&1.evidence, ["decision", "attempt", "attempt_id"]) == attempt_id))
  end

  defp live_job_for_attempt?(work_item_id, attempt_id) do
    process_job_live?(work_item_id, attempt_id) or attempt_job_live?(attempt_id)
  end

  defp process_job_live?(work_item_id, attempt_id) do
    case claim_for_attempt(work_item_id, attempt_id) do
      nil -> false
      event -> live_job?(event.event_id)
    end
  end

  defp attempt_job_live?(attempt_id) do
    Repo.exists?(
      from(job in Oban.Job,
        where:
          job.worker in [
            "Custode.ClaudeAttemptJob",
            "Custode.CodexAttemptJob",
            "Custode.PublicationAttemptJob",
            "Custode.RepairAttemptJob",
            "Custode.VerificationAttemptJob"
          ] and
            job.state in ^@live_job_states and
            fragment("json_extract(?, '$.attempt_id')", job.args) == ^attempt_id
      )
    )
  end

  defp live_job?(decision_id) do
    Repo.exists?(
      from(job in Oban.Job,
        where:
          job.worker == "Custode.WorkCommandJob" and
            job.state in ^@live_job_states and
            fragment("json_extract(?, '$.decision_id')", job.args) == ^decision_id
      )
    )
  end

  defp completed?(decision_id) do
    Repo.exists?(
      from(event in WorkEvent,
        where: event.kind == "work.next_action.completed" and event.causation_id == ^decision_id
      )
    )
  end

  defp verify_command(event, work_item_id, expected_version) do
    cond do
      event.kind != "work.next_action.claimed" -> {:error, :not_process_claim}
      event_work_item_id(event) != work_item_id -> {:error, :work_item_id_mismatch}
      event.work_item_version != expected_version -> {:error, :expected_version_mismatch}
      true -> :ok
    end
  end

  defp definition_unchanged(operation, registry) do
    name = value(operation, :operation)
    expected = value(operation, :definition_fingerprint)

    case OperationRegistry.fetch(registry, name) do
      {:ok, definition} ->
        if OperationDefinition.fingerprint(definition) == expected,
          do: :ok,
          else: {:error, {:stale, :operation_definition_changed}}

      :error ->
        {:error, {:unknown_operation, name}}
    end
  end

  defp restore_envelope(operation, event) do
    attrs =
      operation
      |> atomize()
      |> Map.drop([:definition_fingerprint, :effect_preview])
      |> Map.put(:actor, restore_actor(value(operation, :actor)))
      |> Map.put(:transport, existing_atom(value(operation, :transport)))
      |> Map.put(:correlation_id, event.correlation_id || value(operation, :correlation_id))
      |> Map.put(:causation_id, event.event_id)

    {:ok, envelope} = OperationEnvelope.new(attrs)
    envelope
  end

  defp restore_actor(actor) do
    %{
      kind: actor |> value(:kind) |> existing_atom(),
      id: value(actor, :id)
    }
  end

  defp existing_atom(value) when is_atom(value), do: value
  defp existing_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp event_work_item_id(event) do
    event
    |> Repo.preload(:work_item)
    |> Map.fetch!(:work_item)
    |> Map.fetch!(:work_item_id)
  end

  defp required_snapshot_map(snapshot, field) do
    case value(snapshot, field) do
      map when is_map(map) and map_size(map) > 0 -> {:ok, map}
      _other -> {:error, {:world_snapshot_required, field}}
    end
  end

  defp expected_version(%WorkItem{version: version}, version), do: :ok
  defp expected_version(work_item, expected), do: {:error, stale(work_item, expected)}

  defp stale(work_item, expected) do
    {:stale, :work_item_version_changed,
     %{work_item: %{expected: expected, observed: work_item.version}}}
  end

  defp unique_claim?(changeset) do
    constraint?(changeset, "work_events_next_action_claim_index") or
      constraint?(changeset, "work_events_work_item_id_work_item_version_index")
  end

  defp unique_result?(changeset) do
    constraint?(changeset, "work_events_next_action_result_index") or
      constraint?(changeset, "work_events_causation_id_index")
  end

  defp constraint?(changeset, name) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        options[:constraint] == :unique and options[:constraint_name] == name
    end)
  end

  defp string_list(snapshot, field) do
    case value(snapshot, field) do
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _other -> []
    end
  end

  defp structured?(value), do: is_map(value) and map_size(value) > 0

  defp value(nil, _key), do: nil
  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp put(map, key, value) do
    map
    |> Map.delete(Atom.to_string(key))
    |> Map.put(key, value)
  end

  defp put_policy_evidence(transition, nil), do: transition

  defp put_policy_evidence(transition, policy) do
    evidence = value(transition, :evidence) || %{}
    put(transition, :evidence, put(evidence, :work_policy, policy))
  end

  defp attempt_policy(attempt) do
    attempt
    |> value(:provenance)
    |> value(:work_policy)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

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

  defp json(nil), do: nil
  defp json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_list(value), do: Enum.map(value, &json/1)

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  defp json(value), do: inspect(value)
end
