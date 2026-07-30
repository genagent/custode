defmodule Custode.OperationCalls do
  @moduledoc """
  Durable command claiming, retry, reconciliation, and result replay.

  The unique `(operation, scope, key)` index is the logical-call boundary.
  A short lease prevents concurrent claimants from both invoking the handler;
  an expired lease lets a later physical delivery recover a crashed call.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{OperationCall, OperationDefinition, OperationEnvelope, Repo}

  @lease_seconds 30
  @terminal ~w(succeeded failed denied stale cancelled)

  @type executor :: (OperationDefinition.t(), OperationEnvelope.t() ->
                       {:ok, map()} | {:error, term()})

  @spec dispatch(OperationDefinition.t(), OperationEnvelope.t(), executor()) ::
          {:ok, map()} | {:error, term()}
  def dispatch(definition, envelope, executor) do
    with :ok <- validate_key(envelope.idempotency_key),
         {:ok, scope} <- idempotency_scope(definition, envelope) do
      claim(definition, envelope, scope, executor)
    end
  end

  defp claim(definition, envelope, scope, executor) do
    token = Ecto.UUID.generate()

    case Repo.insert(
           OperationCall.create_changeset(create_attrs(definition, envelope, scope, token))
         ) do
      {:ok, call} ->
        continue(call, definition, envelope, executor, :proposed)

      {:error, changeset} ->
        handle_claim_error(changeset, definition, envelope, scope, executor)
    end
  end

  defp handle_claim_error(changeset, definition, envelope, scope, executor) do
    if idempotency_conflict?(changeset) do
      replay_or_resume(definition, envelope, scope, executor)
    else
      {:error, {:operation_call_failed, changeset}}
    end
  end

  @spec get(String.t()) :: OperationCall.t() | nil
  def get(call_id), do: Repo.get_by(OperationCall, call_id: call_id)

  @doc false
  @spec get_for_invocation(OperationDefinition.t(), OperationEnvelope.t()) ::
          OperationCall.t() | nil
  def get_for_invocation(definition, envelope) do
    case idempotency_scope(definition, envelope) do
      {:ok, scope} ->
        Repo.get_by(OperationCall,
          operation: definition.name,
          idempotency_scope: scope,
          idempotency_key: envelope.idempotency_key
        )

      _error ->
        nil
    end
  end

  defp replay_or_resume(definition, envelope, scope, executor) do
    case authorize(definition, envelope) do
      {:ok, grant} ->
        envelope = %{envelope | grant: grant}

        call =
          Repo.get_by!(OperationCall,
            operation: definition.name,
            idempotency_scope: scope,
            idempotency_key: envelope.idempotency_key
          )

        cond do
          call.status in @terminal ->
            replay(call)

          lease_active?(call) ->
            {:ok, response(call, true)}

          true ->
            reclaim(call, definition, envelope, executor)
        end

      {:error, reason} ->
        {:error, {:denied, reason}}
    end
  end

  defp reclaim(call, definition, envelope, executor) do
    token = Ecto.UUID.generate()
    now = now()
    expires_at = DateTime.add(now, @lease_seconds, :second)

    {claimed, _rows} =
      Repo.update_all(
        from(c in OperationCall,
          where:
            c.id == ^call.id and
              (is_nil(c.lease_expires_at) or c.lease_expires_at <= ^now)
        ),
        set: [lease_token: token, lease_expires_at: expires_at, updated_at: now]
      )

    if claimed == 1 do
      refreshed = Repo.get!(OperationCall, call.id)
      continue_authorized(refreshed, definition, envelope, executor, call.status)
    else
      {:ok, OperationCall |> Repo.get!(call.id) |> response(true)}
    end
  end

  defp continue(call, definition, envelope, executor, prior_status) do
    case authorize(definition, envelope) do
      {:ok, grant} ->
        envelope = %{envelope | grant: grant}
        continue_authorized(call, definition, envelope, executor, prior_status)

      {:error, reason} ->
        _call =
          finish(call, "denied", %{
            authorization_result: %{"decision" => "denied", "reason" => json(reason)},
            error: error("denied", reason)
          })

        {:error, {:denied, reason}}
    end
  end

  defp continue_authorized(call, definition, envelope, executor, prior_status) do
    envelope = %{envelope | call_id: call.call_id}

    call =
      update!(call, %{
        authorization_result: %{
          "decision" => "allowed",
          "grant" => to_string(envelope.grant)
        },
        grant: to_string(envelope.grant)
      })

    with :ok <- check_precondition(call, definition, envelope) do
      resume_or_execute(call, definition, envelope, executor, prior_status)
    end
  end

  defp authorize(%OperationDefinition{} = definition, envelope) do
    with {:ok, grant} <- definition.authorization.(definition, envelope),
         true <- grant in definition.required_grants do
      {:ok, grant}
    else
      false -> {:error, :missing_grant}
      {:error, reason} -> {:error, unwrap_denied(reason)}
    end
  end

  defp unwrap_denied({:denied, reason}), do: reason
  defp unwrap_denied(reason), do: reason

  defp check_precondition(_call, %OperationDefinition{precondition: nil}, _envelope), do: :ok

  defp check_precondition(call, %OperationDefinition{} = definition, envelope) do
    case definition.precondition.(envelope.arguments, envelope) do
      :ok ->
        :ok

      {:stale, reason, observed} ->
        finish(call, "stale", %{
          preconditions: json(observed),
          error: error("stale", reason)
        })

        {:error, {:stale, reason}}
    end
  end

  defp resume_or_execute(call, definition, envelope, executor, prior_status)
       when prior_status in ["running", "waiting"] do
    reconcile(call, definition, envelope, executor)
  end

  defp resume_or_execute(call, definition, envelope, executor, _prior_status) do
    execute(call, definition, envelope, executor)
  end

  defp reconcile(call, %OperationDefinition{reconcile: nil}, _envelope, _executor) do
    call =
      update!(call, %{
        status: "waiting",
        error: error("uncertain_external_outcome", :reconciliation_required),
        lease_token: nil,
        lease_expires_at: nil
      })

    {:ok, response(call, true)}
  end

  defp reconcile(call, definition, envelope, executor) do
    case definition.reconcile.(call) do
      :retry ->
        execute(call, definition, envelope, executor)

      {:ok, result, effects} ->
        call =
          finish(call, "succeeded", %{
            result: json(result),
            effects: effects(effects)
          })

        {:ok, response(call, true)}

      {:waiting, reason} ->
        call =
          update!(call, %{
            status: "waiting",
            error: error("uncertain_external_outcome", reason),
            lease_token: nil,
            lease_expires_at: nil
          })

        {:ok, response(call, true)}
    end
  end

  defp execute(call, definition, envelope, executor) do
    call =
      update!(call, %{
        status: "running",
        started_at: call.started_at || now()
      })

    case executor.(definition, envelope) do
      {:ok, outcome} ->
        call =
          finish(call, "succeeded", %{
            result: json(outcome.result),
            effect_preview: json(outcome.effect_preview),
            effects: effects(outcome.effects)
          })

        {:ok, response(call, false)}

      {:error, {:operation_waiting, reason}} ->
        call =
          update!(call, %{
            status: "waiting",
            error: error("uncertain_external_outcome", reason),
            lease_token: nil,
            lease_expires_at: nil
          })

        {:ok, response(call, false)}

      {:error, {:stale, reason, observed}} ->
        _call =
          finish(call, "stale", %{
            preconditions: json(observed),
            error: error("stale", reason)
          })

        {:error, {:stale, reason}}

      {:error, reason} ->
        {kind, value, public_error} = failure(reason)
        _call = finish(call, "failed", %{error: error(kind, value)})
        {:error, public_error}
    end
  end

  defp replay(%OperationCall{status: "succeeded"} = call), do: {:ok, response(call, true)}

  defp replay(%OperationCall{status: "failed"} = call), do: {:error, replay_failure(call)}

  defp replay(%OperationCall{status: "denied"} = call),
    do: {:error, {:denied, error_value(call)}}

  defp replay(%OperationCall{status: "stale"} = call),
    do: {:error, {:stale, error_value(call)}}

  defp replay(call), do: {:ok, response(call, true)}

  defp response(call, replayed) do
    %{
      call_id: call.call_id,
      status: response_status(call),
      operation: call.operation,
      result: restore_keys(call.result),
      effect_preview: restore_keys(call.effect_preview),
      effects: call.effects |> effect_items() |> restore_keys(),
      actor: restore_actor(call.actor),
      transport: String.to_existing_atom(call.transport),
      grant: call.grant && String.to_existing_atom(call.grant),
      correlation_id: call.correlation_id,
      causation_id: call.causation_id,
      replayed: replayed
    }
  end

  defp response_status(%{dry_run: true, status: "succeeded"}), do: :dry_run
  defp response_status(call), do: String.to_existing_atom(call.status)

  defp effect_items(%{"items" => items}), do: items
  defp effect_items(%{items: items}), do: items
  defp effect_items(_effects), do: []

  defp restore_actor(actor) do
    actor = restore_keys(actor)

    case actor do
      %{kind: kind} when is_binary(kind) -> %{actor | kind: String.to_existing_atom(kind)}
      _other -> actor
    end
  end

  defp restore_keys(nil), do: nil
  defp restore_keys(value) when is_list(value), do: Enum.map(value, &restore_keys/1)

  defp restore_keys(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {existing_atom(key), restore_keys(item)} end)
  end

  defp restore_keys(value), do: value

  defp existing_atom(key) when is_atom(key), do: key

  defp existing_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp error_value(%{error: %{"value" => value}}), do: value
  defp error_value(%{error: %{value: value}}), do: value
  defp error_value(_call), do: nil

  defp replay_failure(%{error: %{"kind" => "handler_failed"}} = call),
    do: {:handler_failed, error_value(call)}

  defp replay_failure(%{error: %{"kind" => "invalid_handler_result"}} = call),
    do: {:invalid_handler_result, error_value(call)}

  defp replay_failure(%{error: %{"kind" => "validation_failed"}} = call),
    do: {:validation_failed, error_value(call)}

  defp replay_failure(call), do: {:operation_failed, error_value(call)}

  defp failure({:handler_failed, reason}),
    do: {"handler_failed", reason, {:handler_failed, reason}}

  defp failure({:invalid_handler_result, result}),
    do: {"invalid_handler_result", result, {:invalid_handler_result, result}}

  defp failure({:validation_failed, errors}),
    do: {"validation_failed", errors, {:validation_failed, errors}}

  defp failure(reason), do: {"operation_failed", reason, reason}

  defp finish(call, status, attrs) do
    update!(
      call,
      Map.merge(attrs, %{
        status: status,
        finished_at: now(),
        lease_token: nil,
        lease_expires_at: nil
      })
    )
  end

  defp update!(call, attrs) do
    call
    |> OperationCall.update_changeset(attrs)
    |> Repo.update!()
  end

  defp create_attrs(definition, envelope, scope, token) do
    %{
      call_id: Ecto.UUID.generate(),
      operation: definition.name,
      arguments: json(envelope.arguments),
      actor: json(envelope.actor),
      transport: to_string(envelope.transport),
      risk: to_string(definition.risk),
      idempotency_scope: scope,
      idempotency_key: envelope.idempotency_key,
      expected_versions: json(envelope.expected_versions),
      correlation_id: envelope.correlation_id,
      causation_id: envelope.causation_id,
      mission_id: reference(envelope.mission_id),
      work_item_id: reference(envelope.work_item_id),
      attempt_id: reference(envelope.attempt_id),
      dry_run: envelope.dry_run,
      status: "proposed",
      lease_token: token,
      lease_expires_at: DateTime.add(now(), @lease_seconds, :second)
    }
  end

  defp idempotency_scope(definition, envelope) do
    case definition.idempotency[:scope] do
      :agent -> argument_scope(envelope.arguments, :agent_id)
      :actor -> {:ok, "#{envelope.actor.kind}:#{envelope.actor.id}"}
      scope when is_binary(scope) and scope != "" -> {:ok, scope}
      fun when is_function(fun, 1) -> normalize_scope(fun.(envelope))
      _other -> {:error, {:invalid_idempotency, :scope}}
    end
  end

  defp argument_scope(arguments, key) do
    case Map.get(arguments, key) || Map.get(arguments, Atom.to_string(key)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, {:invalid_idempotency, :scope}}
    end
  end

  defp normalize_scope(scope) when is_binary(scope) and scope != "", do: {:ok, scope}
  defp normalize_scope(_scope), do: {:error, {:invalid_idempotency, :scope}}

  defp validate_key(key) when is_binary(key) and key != "", do: :ok
  defp validate_key(_key), do: {:error, {:invalid_envelope, :idempotency_key}}

  defp idempotency_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        options[:constraint] == :unique and
          options[:constraint_name] ==
            "operation_calls_operation_idempotency_scope_idempotency_key_index"
    end)
  end

  defp lease_active?(%{lease_expires_at: nil}), do: false
  defp lease_active?(call), do: DateTime.compare(call.lease_expires_at, now()) == :gt

  defp effects(items) when is_list(items), do: %{"items" => json(items)}
  defp effects(_items), do: %{"items" => []}

  defp error(kind, value) do
    %{"kind" => kind, "value" => json(value), "rendered" => inspect(value)}
  end

  defp json(nil), do: nil
  defp json(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json(value) when is_atom(value), do: Atom.to_string(value)
  defp json(value) when is_tuple(value), do: value |> Tuple.to_list() |> json()
  defp json(value) when is_list(value), do: Enum.map(value, &json/1)

  defp json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)
  end

  defp json(value), do: inspect(value)

  defp reference(nil), do: nil
  defp reference(value), do: to_string(value)

  defp now, do: DateTime.utc_now()
end
