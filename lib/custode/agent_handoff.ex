defmodule Custode.AgentHandoff do
  @moduledoc """
  Moves a live routine onto its current execution configuration at a safe
  provider boundary.

  Configuration writes run through `reconfigure/2`, which reloads the roster
  and reconciles every affected routine while provider admission remains
  serialized behind the same coordinator. Delivery paths call `ensure/1`
  before handing work to a provider. An offline routine is already safe for
  its next delivery to start. A compatible live routine is ready immediately.
  A live routine with a stale provider or configuration revision is quiesced
  atomically and delivery is fenced until its current turn, including one
  pending gate continuation, reaches `:paused`.

  The process polls every pending handoff as well as listening to lifecycle
  telemetry. Polling is deliberate: a provider can die without emitting a
  final transition, and telemetry is an accelerator rather than the source of
  truth. The telemetry callback only sends this GenServer a message; provider
  calls always happen in the GenServer.
  """

  use GenServer

  alias Custode.{
    AgentAuthorizationSnapshot,
    AgentHandoffIntent,
    Agents,
    ConversationArcs,
    InboxWakes,
    OperatorMessages,
    ProviderJobs,
    Routine
  }

  alias Custode.Operator.Actions

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_codex, :agent, :transition]
  ]

  @default_poll_interval 1_000
  @default_stop_timeout 5_000

  @type provider :: :claude | :codex
  @type pending :: %{
          provider: provider(),
          preserve_pause?: boolean(),
          phase:
            :draining
            | :fencing
            | :physical_wait
            | :provider_drain
            | :removal_cleanup
            | :preserved
            | :preserving
            | :quiescing
            | :replaying
            | :retrying
        }

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__) || __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_options = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_options)
  end

  @doc """
  Fence one delivery until the routine's live provider has its current config.

  `:ok` means the config fence is open. `{:deferred, :handoff_pending}` means the
  caller must leave its durable work queued and try again after the handoff.
  A compatible paused agent also returns `:ok`; the delivery surface owns its
  existing resume-or-defer policy.
  """
  def ensure(agent_id), do: ensure(__MODULE__, agent_id)

  @doc false
  def ensure(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:ensure, agent_id}, :infinity)
  end

  @doc "Run a short provider-admission operation inside the live-config boundary."
  def admit(agent_id, fun, opts \\ []) when is_function(fun, 0),
    do: admit(__MODULE__, agent_id, fun, opts)

  @doc false
  def admit(server, agent_id, fun, opts)
      when is_binary(agent_id) and is_function(fun, 0) and is_list(opts) do
    GenServer.call(server, {:admit, agent_id, fun, opts}, :infinity)
  end

  @doc "Serialize a safety pause with configuration handoff ownership."
  def pause(agent_id, context, fun)
      when is_binary(agent_id) and is_map(context) and is_function(fun, 0),
      do: pause(__MODULE__, agent_id, context, fun)

  @doc false
  def pause(server, agent_id, context, fun)
      when is_binary(agent_id) and is_map(context) and is_function(fun, 0) do
    GenServer.call(server, {:pause, agent_id, context, fun}, :infinity)
  end

  @doc "Serialize an explicit resume with configuration handoff ownership."
  def resume(agent_id, fun) when is_binary(agent_id) and is_function(fun, 0),
    do: resume(__MODULE__, agent_id, fun)

  @doc false
  def resume(server, agent_id, fun) when is_binary(agent_id) and is_function(fun, 0) do
    GenServer.call(server, {:resume, agent_id, fun}, :infinity)
  end

  @doc "Notify the coordinator after durable work becomes replayable."
  def work_queued(agent_id) when is_binary(agent_id) do
    GenServer.cast(__MODULE__, {:work_queued, agent_id})
  end

  @doc """
  Notice a roster change and begin any required safe handoff.

  This call is synchronous through the initial compatibility check and atomic
  quiesce. A pending turn or gate completes in the background.
  """
  def reconcile(agent_id), do: reconcile(__MODULE__, agent_id)

  @doc false
  def reconcile(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:reconcile, agent_id}, :infinity)
  end

  @doc """
  Apply one roster reload and reconcile every affected routine before admissions resume.

  The callback may return `{:ok, result, additional_agent_ids}` or
  `{:error, reason, additional_agent_ids}` when the authoritative affected set
  can only be known inside the serialized configuration operation.
  """
  def reconfigure(agent_ids, fun) when is_list(agent_ids) and is_function(fun, 0),
    do: reconfigure(__MODULE__, agent_ids, fun)

  @doc false
  def reconfigure(server, agent_ids, fun) when is_list(agent_ids) and is_function(fun, 0) do
    if Enum.all?(agent_ids, &(is_binary(&1) and &1 != "")) do
      GenServer.call(server, {:reconfigure, Enum.uniq(agent_ids), fun}, :infinity)
    else
      {:error, :invalid_agent_ids}
    end
  end

  @doc "Return the coordinator's small, provider-neutral state for one routine."
  def status(agent_id), do: status(__MODULE__, agent_id)

  @doc false
  def status(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:status, agent_id}, :infinity)
  end

  @doc """
  Return the routine contract that may authorize MCP calls at this boundary.

  Authorization follows the exact execution revision owned by the live
  provider or an active durable turn. A roster write therefore cannot change
  role, repository, or path authority underneath an old turn. The durable
  revision snapshot also survives coordinator and node restarts.
  """
  def authorization_routine(agent_id), do: authorization_routine(__MODULE__, agent_id)

  @doc false
  def authorization_routine(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:authorization_routine, agent_id}, :infinity)
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  @doc "Return the role that may authorize MCP discovery at this boundary."
  def authorization_role(agent_id), do: authorization_role(__MODULE__, agent_id)

  @doc false
  def authorization_role(server, agent_id) when is_binary(agent_id) do
    GenServer.call(server, {:authorization_role, agent_id}, :infinity)
  catch
    :exit, _reason -> {:error, :coordinator_unavailable}
  end

  @doc false
  def handle_transition(_event, _measurements, %{agent_id: agent_id} = meta, target)
      when is_binary(agent_id) do
    send(target, {:provider_transition, agent_id, meta})
    :ok
  end

  def handle_transition(_event, _measurements, _meta, _target), do: :ok

  @impl GenServer
  def init(opts) do
    target = self()
    handler_id = Keyword.get(opts, :handler_id, "custode-agent-handoff")

    # A hard crash does not invoke terminate/2. Detach first so the restarted
    # child replaces its old callback instead of losing transition wakeups.
    :telemetry.detach(handler_id)
    :ok = :telemetry.attach_many(handler_id, @events, &__MODULE__.handle_transition/4, target)

    state = %{
      dependencies: dependencies(opts),
      handler_id: handler_id,
      pending: %{},
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      poll_timer: nil,
      stop_timeout: Keyword.get(opts, :stop_timeout, @default_stop_timeout)
    }

    # Pending phases are rebuilt from provider and job truth. A non-config
    # pause has one small durable intent row covering the stop/start crash
    # window. Reconcile both before the supervisor can advance to MCP.Probe and
    # Scheduler. This child is the boot fence, so an unavailable durable queue
    # or roster must fail startup rather than release ticks without a
    # trustworthy boundary.
    case boot_reconcile(state) do
      {:ok, state} ->
        {:ok, schedule_poll(state)}

      {:error, reason} ->
        :telemetry.detach(handler_id)
        {:stop, {:boot_reconciliation_failed, reason}}
    end
  end

  @impl GenServer
  def handle_call({:ensure, agent_id}, _from, state) do
    {result, state} = reconcile_one(agent_id, state)

    reply =
      case {result, Map.get(state.pending, agent_id)} do
        {{:error, reason}, _pending} -> {:error, reason}
        {_result, %{phase: phase}} when phase in [:draining, :preserved] -> :ok
        {_result, nil} -> :ok
        {_result, _pending} -> {:deferred, :handoff_pending}
      end

    {:reply, reply, schedule_poll(state)}
  end

  def handle_call({:admit, agent_id, fun, opts}, _from, state) do
    {reply, state} = serialized_admission(agent_id, fun, opts, state)

    {:reply, reply, schedule_poll(state)}
  end

  def handle_call({:pause, agent_id, context, fun}, _from, state) do
    {reply, state} = serialized_pause(agent_id, context, fun, state)
    {:reply, reply, schedule_poll(state)}
  end

  def handle_call({:resume, agent_id, fun}, _from, state) do
    {reply, state} = serialized_resume(agent_id, fun, state)
    {:reply, reply, schedule_poll(state)}
  end

  def handle_call({:reconcile, agent_id}, _from, state) do
    {result, state} = reconcile_one(agent_id, state)

    reply =
      case result do
        {:error, reason} -> {:error, reason}
        _ready_or_pending -> :ok
      end

    {:reply, reply, schedule_poll(state)}
  end

  def handle_call({:reconfigure, agent_ids, fun}, _from, state) do
    case snapshot_current_authorizations(state) do
      :ok ->
        configured_before = configured_ids(agent_ids, state)

        {callback_result, callback_agent_ids} =
          fun
          |> invoke_admission()
          |> normalize_reconfigure_callback()

        snapshot_result = snapshot_current_authorizations(state)
        targets = Enum.uniq(agent_ids ++ callback_agent_ids)
        removed_ids = removed_ids(callback_result, configured_before, state)
        {failures, state} = reconcile_many(targets, state, removed_ids)
        reply = reconfigure_reply(callback_result, snapshot_result, failures)

        {:reply, reply, schedule_poll(state)}

      {:error, reason} ->
        {:reply, {:error, {:authorization_snapshot, reason}}, state}
    end
  end

  def handle_call({:status, agent_id}, _from, state) do
    reply =
      case Map.fetch(state.pending, agent_id) do
        {:ok, %{phase: :draining}} -> :ready
        {:ok, pending} -> {:pending, pending}
        :error -> :ready
      end

    {:reply, reply, state}
  end

  def handle_call({:authorization_routine, agent_id}, _from, state) do
    reply = authorization_routine_reply(agent_id, state)
    {:reply, reply, state}
  end

  def handle_call({:authorization_role, agent_id}, _from, state) do
    reply = authorization_role_reply(agent_id, state)

    {:reply, reply, state}
  end

  defp authorization_role_reply(agent_id, state) do
    case authorization_revision(agent_id, state) do
      {:ok, revision} ->
        with {:ok, routine} <- authorization_snapshot(agent_id, revision, state) do
          authorization_role_from(routine)
        end

      :none ->
        authorize_current_role_without_execution_owner(agent_id, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp authorization_role_from(routine) do
    case value(routine, :role, :assistant) do
      role when is_atom(role) -> {:ok, role}
      other -> {:error, {:authorization_role, {:unexpected_reply, other}}}
    end
  end

  defp authorize_current_role_without_execution_owner(agent_id, state) do
    if Map.has_key?(state.pending, agent_id) do
      {:error, :handoff_pending}
    else
      case invoke(state, :routine_role, [agent_id]) do
        nil -> {:error, :unknown_routine}
        role when is_atom(role) -> {:ok, role}
        {:error, reason} -> {:error, {:routine_role, reason}}
        other -> {:error, {:routine_role, {:unexpected_reply, other}}}
      end
    end
  end

  defp authorization_routine_reply(agent_id, state) do
    case authorization_revision(agent_id, state) do
      {:ok, revision} ->
        authorization_snapshot(agent_id, revision, state)

      :none ->
        authorize_without_execution_owner(agent_id, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp authorization_revision(agent_id, state) do
    case invoke(state, :live_provider, [agent_id]) do
      {:ok, provider} -> live_authorization_revision(agent_id, provider, state)
      :offline -> durable_authorization_revision(agent_id, state)
      {:error, :multiple_live_providers} -> {:error, :ambiguous_authorization_revision}
      {:error, reason} -> {:error, {:live_provider, reason}}
      other -> {:error, {:live_provider, {:unexpected_reply, other}}}
    end
  end

  defp live_authorization_revision(agent_id, provider, state) do
    case invoke(state, :info, [agent_id, provider]) do
      {:ok, info} ->
        case value(info, :config_revision) do
          revision when is_binary(revision) and revision != "" -> {:ok, revision}
          _missing -> {:error, :missing_authorization_revision}
        end

      {:error, :agent_not_running} ->
        durable_authorization_revision(agent_id, state)

      {:error, reason} ->
        {:error, {:info, reason}}

      other ->
        {:error, {:info, {:unexpected_reply, other}}}
    end
  end

  defp durable_authorization_revision(agent_id, state) do
    case invoke(state, :active_turns, [agent_id]) do
      [] ->
        :none

      turns when is_list(turns) ->
        durable_revision_from(turns)

      {:error, reason} ->
        {:error, {:active_turns, reason}}

      other ->
        {:error, {:active_turns, {:unexpected_reply, other}}}
    end
  end

  defp durable_revision_from(turns) do
    revisions = Enum.map(turns, &turn_authorization_revision/1)

    with true <- Enum.all?(revisions, &(is_binary(&1) and &1 != "")),
         [revision] <- Enum.uniq(revisions) do
      {:ok, revision}
    else
      false -> {:error, :missing_authorization_revision}
      _many -> {:error, :ambiguous_authorization_revision}
    end
  end

  defp turn_authorization_revision(turn) do
    turn
    |> value(:meta, %{})
    |> value(:config_revision)
  end

  defp authorize_without_execution_owner(agent_id, state) do
    if Map.has_key?(state.pending, agent_id) do
      {:error, :handoff_pending}
    else
      case desired(agent_id, state) do
        {:ok, desired} -> authorization_snapshot(agent_id, desired.revision, state)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp authorization_snapshot(agent_id, revision, state) do
    case invoke(state, :authorization_get, [agent_id, revision]) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      nil -> recover_current_authorization_snapshot(agent_id, revision, state)
      {:error, reason} -> {:error, {:authorization_snapshot, reason}}
      other -> {:error, {:authorization_snapshot, {:unexpected_reply, other}}}
    end
  end

  defp recover_current_authorization_snapshot(agent_id, revision, state) do
    with routine when is_map(routine) <- invoke(state, :routine_get, [agent_id]),
         ^revision <- invoke(state, :execution_revision, [routine]),
         :ok <- snapshot_authorization(routine, revision, state),
         snapshot when is_map(snapshot) <-
           invoke(state, :authorization_get, [agent_id, revision]) do
      {:ok, snapshot}
    else
      {:error, reason} -> {:error, {:authorization_snapshot, reason}}
      _missing_or_different -> {:error, {:authorization_snapshot_missing, revision}}
    end
  end

  defp serialized_admission(agent_id, fun, opts, state) do
    cond do
      Keyword.get(opts, :continuation, false) and continuation_ready?(agent_id, state) ->
        {invoke_admission(agent_id, fun, opts, state), state}

      replay_owned_admission?(Map.get(state.pending, agent_id), opts) ->
        # The coordinator already owns replay order. Advancing it here can
        # submit this freshly inserted row, then invoke `fun` a second time
        # from the same call after the phase becomes `:draining`.
        {{:deferred, :handoff_pending}, state}

      true ->
        reconcile_admission(agent_id, fun, opts, state)
    end
  end

  defp reconcile_admission(agent_id, fun, opts, state) do
    # A newly persisted operator message may itself be the oldest durable
    # work. When its caller is already inside this serialized admission,
    # let that callback start an offline agent and preserve the caller's
    # exact `:started` receipt. Older queued work still takes the recovery
    # path first.
    recover_queued? = not Keyword.get(opts, :current_queue_head, false)
    {result, state} = reconcile_one(agent_id, state, recover_queued?: recover_queued?)
    pending = Map.get(state.pending, agent_id)
    reply = reconciled_admission(result, pending, agent_id, fun, opts, state)

    {reply, state}
  end

  defp reconciled_admission({:error, reason}, _pending, _agent_id, _fun, _opts, _state),
    do: {:error, reason}

  defp reconciled_admission(_result, nil, agent_id, fun, opts, state),
    do: invoke_admission(agent_id, fun, opts, state)

  defp reconciled_admission(_result, %{phase: :preserved}, agent_id, fun, opts, state) do
    if Keyword.get(opts, :allow_preserved, false),
      do: invoke_admission(agent_id, fun, opts, state),
      else: {:deferred, :handoff_pending}
  end

  defp reconciled_admission(_result, _pending, _agent_id, _fun, _opts, _state),
    do: {:deferred, :handoff_pending}

  defp normalize_reconfigure_callback({:ok, result, agent_ids}) when is_list(agent_ids) do
    if valid_agent_ids?(agent_ids) do
      {{:ok, result}, agent_ids}
    else
      {{:error, :invalid_reconfigure_agent_ids}, []}
    end
  end

  defp normalize_reconfigure_callback({:error, reason, agent_ids}) when is_list(agent_ids) do
    if valid_agent_ids?(agent_ids) do
      {{:error, reason}, agent_ids}
    else
      {{:error, :invalid_reconfigure_agent_ids}, []}
    end
  end

  defp normalize_reconfigure_callback(result), do: {result, []}

  defp reconfigure_reply(callback_result, :ok, failures) do
    case {callback_result, failures} do
      {{:ok, result}, []} ->
        {:ok, result}

      {{:ok, result}, failures} ->
        {:error, {:config_applied_reconcile_pending, result, failures}}

      {{:error, reason}, []} ->
        {:error, reason}

      {{:error, reason}, failures} ->
        {:error, {:reconfigure_failed_reconcile_pending, reason, failures}}

      {other, []} ->
        {:error, {:invalid_reconfigure_reply, other}}

      {other, failures} ->
        {:error, {:invalid_reconfigure_reply_reconcile_pending, other, failures}}
    end
  end

  defp reconfigure_reply({:ok, result}, {:error, reason}, failures) do
    {:error, {:config_applied_authorization_snapshot_failed, result, reason, failures}}
  end

  defp reconfigure_reply({:error, callback_reason}, {:error, reason}, failures) do
    {:error, {:reconfigure_failed_authorization_snapshot, callback_reason, reason, failures}}
  end

  defp reconfigure_reply(other, {:error, reason}, failures) do
    {:error, {:invalid_reconfigure_reply_authorization_snapshot_failed, other, reason, failures}}
  end

  defp valid_agent_ids?(agent_ids) do
    Enum.all?(agent_ids, &(is_binary(&1) and &1 != ""))
  end

  defp replay_owned_admission?(pending, opts) do
    durable? = Keyword.get(opts, :durable_message, false)

    case pending do
      %{phase: phase} when phase in [:replaying, :draining] ->
        true

      %{phase: :preserved} ->
        durable? and not Keyword.get(opts, :current_queue_head, false)

      _other ->
        false
    end
  end

  defp serialized_pause(agent_id, context, fun, state) do
    case invoke(state, :put_pause_intent, [agent_id, context]) do
      :ok ->
        pending = preserving_pending(agent_id, state)
        state = put_pending(state, agent_id, pending)
        {invoke_admission(fun), state}

      {:error, reason} ->
        {{:error, {:pause_intent, reason}}, retain_retry(agent_id, state)}

      other ->
        reason = {:unexpected_reply, other}
        {{:error, {:pause_intent, reason}}, retain_retry(agent_id, state)}
    end
  end

  defp serialized_resume(agent_id, fun, state) do
    reply = invoke_admission(fun)

    if reply in [:ok, :resumed] do
      case clear_pause_intent(agent_id, state) do
        :ok -> {reply, release_preserved_pause(agent_id, state)}
        {:error, reason} -> {{:error, {:pause_intent, reason}}, retain_retry(agent_id, state)}
      end
    else
      {reply, state}
    end
  end

  defp preserving_pending(agent_id, state) do
    existing = Map.get(state.pending, agent_id, %{})

    provider =
      case Map.get(existing, :provider) do
        provider when provider in [:claude, :codex] -> provider
        _missing -> configured_provider(agent_id, state)
      end

    %{
      provider: provider,
      preserve_pause?: true,
      phase: :preserving
    }
  end

  defp configured_provider(agent_id, state) do
    case invoke(state, :routine_get, [agent_id]) do
      routine when is_map(routine) -> value(routine, :provider)
      _missing -> nil
    end
  end

  defp release_preserved_pause(agent_id, state) do
    case Map.fetch(state.pending, agent_id) do
      {:ok, %{phase: phase} = pending} when phase in [:preserved, :preserving] ->
        put_pending(state, agent_id, %{
          pending
          | preserve_pause?: false,
            phase: :replaying
        })

      {:ok, pending} ->
        put_pending(state, agent_id, %{pending | preserve_pause?: false})

      :error ->
        state
    end
  end

  @impl GenServer
  def handle_cast({:work_queued, agent_id}, state) do
    {_result, state} = activate_replay(agent_id, state)
    {:noreply, schedule_poll(state)}
  end

  @impl GenServer
  def handle_info({:provider_transition, agent_id, _meta}, state) do
    # Re-detect even when this process has no pending entry. That covers a
    # transition sent just before a coordinator crash and restart.
    {_result, state} = reconcile_one(agent_id, state)

    {:noreply, schedule_poll(state)}
  end

  def handle_info(:poll_pending, state) do
    state = %{state | poll_timer: nil}

    state =
      state.pending
      |> Map.keys()
      |> Enum.reduce(state, fn agent_id, acc ->
        {_result, acc} = reconcile_one(agent_id, acc)
        acc
      end)

    {:noreply, schedule_poll(state)}
  end

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.handler_id)
    :ok
  end

  defp reconcile_one(agent_id, state, opts \\ []) do
    {result, state} =
      case Map.fetch(state.pending, agent_id) do
        {:ok, pending} -> advance_pending(agent_id, pending, state)
        :error -> detect_mismatch(agent_id, state, opts)
      end

    case result do
      {:error, _reason} -> {result, retain_retry(agent_id, state)}
      _ready_pending_or_paused -> {result, state}
    end
  end

  defp configured_ids(agent_ids, state) do
    agent_ids
    |> Enum.filter(fn agent_id -> is_map(invoke(state, :routine_get, [agent_id])) end)
    |> MapSet.new()
  end

  defp removed_ids({:ok, _result}, configured_before, state) do
    configured_before
    |> Enum.filter(fn agent_id -> is_nil(invoke(state, :routine_get, [agent_id])) end)
    |> MapSet.new()
  end

  defp removed_ids(_callback_result, _configured_before, _state), do: MapSet.new()

  defp reconcile_many(agent_ids, state, removed_ids) do
    Enum.reduce(agent_ids, {[], state}, fn agent_id, {failures, state} ->
      result =
        if MapSet.member?(removed_ids, agent_id) do
          forget_removed(agent_id, state, true)
        else
          reconcile_one(agent_id, state)
        end

      case result do
        {{:error, reason}, state} -> {[{agent_id, reason} | failures], state}
        {_ready_or_pending, state} -> {failures, state}
      end
    end)
    |> then(fn {failures, state} -> {Enum.reverse(failures), state} end)
  end

  defp retain_retry(agent_id, state) do
    if Map.has_key?(state.pending, agent_id) do
      state
    else
      provider =
        case invoke(state, :routine_get, [agent_id]) do
          routine when is_map(routine) -> value(routine, :provider)
          _missing -> nil
        end

      put_pending(state, agent_id, %{
        provider: provider,
        preserve_pause?: false,
        phase: :retrying
      })
    end
  end

  defp detect_mismatch(agent_id, state, opts \\ []) do
    with {:ok, desired} <- desired(agent_id, state),
         live <- invoke(state, :live_provider, [agent_id]) do
      case live do
        :offline ->
          reconcile_offline(agent_id, desired, state, opts)

        {:ok, provider} ->
          detect_live_mismatch(agent_id, provider, desired, state, opts)

        {:error, :multiple_live_providers} ->
          {{:error, :multiple_live_providers}, state}

        other ->
          {{:error, {:live_provider, other}}, state}
      end
    else
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
    end
  end

  defp reconcile_offline(agent_id, desired, state, opts) do
    case fence_stale_ticks(agent_id, desired, state) do
      :ok ->
        reconcile_offline_after_fence(agent_id, desired, state, opts)

      :wait ->
        pending = %{
          provider: desired.provider,
          preserve_pause?: false,
          phase: :fencing
        }

        {:pending, put_pending(state, agent_id, pending)}

      {:error, reason} ->
        {{:error, {:fence_stale_ticks, reason}}, state}
    end
  end

  defp reconcile_offline_after_fence(agent_id, desired, state, opts) do
    case pause_intent(agent_id, state) do
      {:ok, pause_context} ->
        reconcile_offline_activity(agent_id, desired, is_map(pause_context), state, opts)

      {:error, reason} ->
        {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp reconcile_offline_activity(agent_id, desired, preserve_pause?, state, opts) do
    case invoke(state, :active_turn?, [agent_id]) do
      true ->
        pending = offline_pending(desired.provider, preserve_pause?, :physical_wait)
        {:pending, put_pending(state, agent_id, pending)}

      false ->
        replay_offline_if_needed(agent_id, desired, preserve_pause?, state, opts)

      {:error, reason} ->
        {{:error, {:active_turn, reason}}, state}

      other ->
        {{:error, {:active_turn, {:unexpected_reply, other}}}, state}
    end
  end

  defp replay_offline_if_needed(agent_id, desired, preserve_pause?, state, opts) do
    recover_queued? =
      Keyword.get(opts, :recover_queued?, true) and invoke(state, :queued?, [agent_id])

    if preserve_pause? or recover_queued? do
      pending = offline_pending(desired.provider, preserve_pause?, :replaying)
      start_latest(agent_id, pending, put_pending(state, agent_id, pending))
    else
      {:ready, state}
    end
  end

  defp offline_pending(provider, preserve_pause?, phase) do
    %{provider: provider, preserve_pause?: preserve_pause?, phase: phase}
  end

  defp detect_live_mismatch(agent_id, provider, desired, state, opts) do
    case invoke(state, :info, [agent_id, provider]) do
      {:ok, info} -> live_compatibility(agent_id, provider, info, desired, state, opts)
      {:error, :agent_not_running} -> detect_mismatch(agent_id, state, opts)
      {:error, reason} -> {{:error, {:info, reason}}, state}
      other -> {{:error, {:info, other}}, state}
    end
  end

  defp live_compatibility(agent_id, provider, info, desired, state, opts) do
    case fence_stale_ticks(agent_id, desired, state) do
      :ok ->
        live_after_fence(agent_id, provider, info, desired, state, opts)

      :wait ->
        pending = %{
          provider: provider,
          preserve_pause?: existing_non_config_pause?(info),
          phase: :fencing
        }

        {:pending, put_pending(state, agent_id, pending)}

      {:error, reason} ->
        {{:error, {:fence_stale_ticks, reason}}, state}
    end
  end

  defp live_after_fence(agent_id, provider, info, desired, state, opts) do
    case pause_intent(agent_id, state) do
      {:ok, pause_context} ->
        compatible_live_state(agent_id, provider, info, desired, pause_context, state, opts)

      {:error, reason} ->
        {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp compatible_live_state(agent_id, provider, info, desired, pause_context, state, opts) do
    live_state = value(info, :state)

    cond do
      not compatible?(provider, info, desired) ->
        begin_handoff(agent_id, provider, info, state, opts)

      is_map(pause_context) and live_state == :paused ->
        clear_applied_pause_intent(agent_id, state)

      is_map(pause_context) ->
        preserve_compatible_live(agent_id, provider, desired, state)

      live_state == :paused and config_change_pause?(info) ->
        finish_reverted_handoff(
          agent_id,
          %{provider: provider, preserve_pause?: false, phase: :quiescing},
          state
        )

      live_state == :paused ->
        {:paused, state}

      true ->
        {:ready, state}
    end
  end

  defp clear_applied_pause_intent(agent_id, state) do
    case clear_pause_intent(agent_id, state) do
      :ok -> {:paused, state}
      {:error, reason} -> {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp preserve_compatible_live(agent_id, provider, desired, state) do
    pending = %{provider: provider, preserve_pause?: true, phase: :preserving}

    advance_preserving_live(
      agent_id,
      provider,
      desired,
      pending,
      put_pending(state, agent_id, pending)
    )
  end

  defp begin_handoff(agent_id, provider, info, state, opts \\ []) do
    case preserved_pause_context(agent_id, info, state) do
      {:ok, pause_context} ->
        begin_handoff_with_context(agent_id, provider, is_map(pause_context), state, opts)

      {:error, reason} ->
        {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp begin_handoff_with_context(agent_id, provider, preserve_pause?, state, opts) do
    outcome = invoke(state, :quiesce, [agent_id, provider, :config_change])

    continue_quiesce(agent_id, provider, preserve_pause?, outcome, state, opts)
  end

  defp continue_quiesce(agent_id, provider, preserve_pause?, outcome, state, opts) do
    case classify_quiesce(outcome, preserve_pause?) do
      :draining ->
        pending = %{
          provider: provider,
          preserve_pause?: preserve_pause?,
          phase: :provider_drain
        }

        {:pending, put_pending(state, agent_id, pending)}

      {:pending, extra_preserve?} ->
        pending = %{
          provider: provider,
          preserve_pause?: preserve_pause? or extra_preserve?,
          phase: :quiescing
        }

        state = put_pending(state, agent_id, pending)
        advance_pending(agent_id, pending, state)

      :offline ->
        detect_mismatch(agent_id, state, opts)

      {:error, reason} ->
        {{:error, {:quiesce, reason}}, state}
    end
  end

  # Keep this translation local. The provider packages own their richer
  # reply vocabulary; the coordinator only needs pending, offline, or failed.
  defp classify_quiesce(:paused, _preserve_pause?), do: {:pending, false}
  defp classify_quiesce(:armed, _preserve_pause?), do: {:pending, false}
  defp classify_quiesce(:already_paused, _preserve_pause?), do: {:pending, false}
  defp classify_quiesce(:draining, _preserve_pause?), do: :draining
  defp classify_quiesce({:error, :agent_not_running}, _preserve_pause?), do: :offline
  defp classify_quiesce({:error, reason}, _preserve_pause?), do: {:error, reason}
  defp classify_quiesce(other, _preserve_pause?), do: {:error, {:unexpected_reply, other}}

  defp advance_pending(agent_id, %{phase: :fencing}, state) do
    case desired(agent_id, state) do
      {:ok, desired} ->
        advance_fence(agent_id, desired, state)

      {:error, :unknown_routine} ->
        forget_removed(agent_id, state)
    end
  end

  defp advance_pending(agent_id, %{phase: :retrying}, state) do
    detect_mismatch(agent_id, delete_pending(state, agent_id))
  end

  defp advance_pending(agent_id, %{phase: :removal_cleanup}, state) do
    forget_removed(agent_id, state, true)
  end

  defp advance_pending(agent_id, %{phase: :provider_drain} = pending, state) do
    outcome = invoke(state, :quiesce, [agent_id, pending.provider, :config_change])

    continue_quiesce(
      agent_id,
      pending.provider,
      pending.preserve_pause?,
      outcome,
      state,
      []
    )
  end

  defp advance_pending(agent_id, %{phase: :preserving} = pending, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> advance_preserving(agent_id, desired, pending, state)
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
    end
  end

  defp advance_pending(agent_id, %{phase: :replaying} = pending, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> advance_replay_owner(agent_id, desired, pending, state)
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
    end
  end

  defp advance_pending(agent_id, %{phase: :draining} = pending, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> advance_replay_owner(agent_id, desired, pending, state)
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
    end
  end

  defp advance_pending(agent_id, %{phase: :physical_wait}, state) do
    case invoke(state, :active_turn?, [agent_id]) do
      true ->
        {:pending, state}

      false ->
        detect_mismatch(agent_id, delete_pending(state, agent_id))

      {:error, reason} ->
        {{:error, {:active_turn, reason}}, state}

      other ->
        {{:error, {:active_turn, {:unexpected_reply, other}}}, state}
    end
  end

  defp advance_pending(agent_id, %{phase: :preserved} = pending, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> advance_preserved(agent_id, desired, pending, state)
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
    end
  end

  defp advance_pending(agent_id, pending, state) do
    case invoke(state, :status, [agent_id, pending.provider]) do
      {:ok, status} ->
        advance_status(agent_id, state_of(status), pending, state)

      {:error, :agent_not_running} ->
        start_after_physical_boundary(agent_id, pending, state)

      other ->
        {{:error, {:status, other}}, state}
    end
  end

  defp advance_fence(agent_id, desired, state) do
    case fence_stale_ticks(agent_id, desired, state) do
      :wait ->
        {:pending, state}

      :ok ->
        detect_mismatch(agent_id, delete_pending(state, agent_id))

      {:error, reason} ->
        {{:error, {:fence_stale_ticks, reason}}, state}
    end
  end

  defp advance_replay_owner(agent_id, desired, pending, state) do
    case invoke(state, :live_provider, [agent_id]) do
      {:ok, provider} -> advance_replay(agent_id, provider, desired, pending, state)
      :offline -> start_after_physical_boundary(agent_id, pending, state)
      {:error, :multiple_live_providers} -> {{:error, :multiple_live_providers}, state}
      other -> {{:error, {:live_provider, other}}, state}
    end
  end

  defp advance_preserving(agent_id, desired, pending, state) do
    case invoke(state, :live_provider, [agent_id]) do
      {:ok, provider} -> advance_preserving_live(agent_id, provider, desired, pending, state)
      :offline -> start_after_physical_boundary(agent_id, pending, state)
      {:error, :multiple_live_providers} -> {{:error, :multiple_live_providers}, state}
      other -> {{:error, {:live_provider, other}}, state}
    end
  end

  defp advance_preserving_live(agent_id, provider, desired, pending, state) do
    with {:ok, info} <- invoke(state, :info, [agent_id, provider]),
         {:ok, status} <- invoke(state, :status, [agent_id, provider]) do
      cond do
        not compatible?(provider, info, desired) ->
          begin_handoff(agent_id, provider, info, state)

        state_of(status) == :paused ->
          finish_preserving(agent_id, provider, state)

        deferred_pause_pending?(info) ->
          {:pending, put_pending(state, agent_id, %{pending | provider: provider})}

        true ->
          preserve_pause(agent_id, provider, state)
      end
    else
      {:error, :agent_not_running} -> start_after_physical_boundary(agent_id, pending, state)
      other -> {{:error, {:preserving, other}}, state}
    end
  end

  defp advance_preserved(agent_id, desired, pending, state) do
    case invoke(state, :live_provider, [agent_id]) do
      {:ok, provider} -> advance_preserved_live(agent_id, provider, desired, pending, state)
      :offline -> start_after_physical_boundary(agent_id, pending, state)
      {:error, :multiple_live_providers} -> {{:error, :multiple_live_providers}, state}
      other -> {{:error, {:live_provider, other}}, state}
    end
  end

  defp advance_preserved_live(agent_id, provider, desired, pending, state) do
    with {:ok, info} <- invoke(state, :info, [agent_id, provider]),
         {:ok, status} <- invoke(state, :status, [agent_id, provider]) do
      cond do
        not compatible?(provider, info, desired) ->
          begin_handoff(agent_id, provider, info, state)

        state_of(status) == :paused ->
          {:paused, state}

        true ->
          pending = %{pending | provider: provider, phase: :replaying}
          {:pending, put_pending(state, agent_id, pending)}
      end
    else
      {:error, :agent_not_running} -> start_after_physical_boundary(agent_id, pending, state)
      other -> {{:error, {:preserved_replacement, other}}, state}
    end
  end

  defp advance_status(agent_id, :offline, pending, state),
    do: start_after_physical_boundary(agent_id, pending, state)

  defp advance_status(agent_id, :paused, pending, state) do
    with {:ok, info} <- invoke(state, :info, [agent_id, pending.provider]),
         {:ok, desired} <- desired(agent_id, state),
         {:ok, pause_context} <- preserved_pause_context(agent_id, info, state) do
      pending = %{
        pending
        | preserve_pause?: pending.preserve_pause? or is_map(pause_context)
      }

      advance_paused_replacement(agent_id, info, desired, pending, state)
    else
      {:error, :agent_not_running} -> start_after_physical_boundary(agent_id, pending, state)
      {:error, :unknown_routine} -> forget_removed(agent_id, state)
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp advance_status(agent_id, :idle, pending, state) do
    # A resume can clear the quiesce latch while configuration is still stale.
    # Re-arm it instead of allowing the next delivery through the gap.
    info =
      case invoke(state, :info, [agent_id, pending.provider]) do
        {:ok, info} -> info
        _missing -> %{}
      end

    begin_handoff(agent_id, pending.provider, info, state)
  end

  defp advance_status(_agent_id, state_name, _pending, state)
       when state_name in [:running, :waiting_for_user, :awaiting_permission],
       do: {:pending, state}

  defp advance_status(_agent_id, _unknown, _pending, state), do: {:pending, state}

  defp advance_paused_replacement(agent_id, info, desired, pending, state) do
    if compatible?(pending.provider, info, desired) do
      finish_reverted_handoff(agent_id, pending, state)
    else
      replace_paused_agent(agent_id, pending, state)
    end
  end

  defp replace_paused_agent(agent_id, pending, state) do
    with :ok <- classify_replay(invoke(state, :defer_unstarted, [agent_id])),
         :ok <- stop_and_wait(agent_id, pending.provider, state) do
      start_after_physical_boundary(
        agent_id,
        pending,
        put_pending(state, agent_id, pending)
      )
    else
      {:error, reason} -> {{:error, reason}, put_pending(state, agent_id, pending)}
    end
  end

  defp advance_replay(agent_id, provider, desired, pending, state) do
    with {:ok, info} <- invoke(state, :info, [agent_id, provider]),
         {:ok, status} <- invoke(state, :status, [agent_id, provider]) do
      cond do
        not compatible?(provider, info, desired) ->
          begin_handoff(agent_id, provider, info, state)

        state_of(status) in [:idle, :waiting_for_user] ->
          replay(agent_id, pending, state)

        state_of(status) == :paused ->
          # A pause that arrived after replacement belongs to the operator or
          # another safety rail. Keep it and retain replay ownership until a
          # later resume opens the fence.
          retain_paused_replay(agent_id, pending, state)

        true ->
          {:pending, state}
      end
    else
      {:error, :agent_not_running} -> start_after_physical_boundary(agent_id, pending, state)
      other -> {{:error, {:replacement, other}}, state}
    end
  end

  defp retain_paused_replay(agent_id, pending, state) do
    if invoke(state, :queued?, [agent_id]) do
      pending = %{pending | preserve_pause?: true, phase: :preserved}
      {:paused, put_pending(state, agent_id, pending)}
    else
      {:paused, delete_pending(state, agent_id)}
    end
  end

  defp start_latest(agent_id, pending, state) do
    case desired(agent_id, state) do
      {:error, :unknown_routine} ->
        forget_removed(agent_id, state)

      {:ok, desired} ->
        # A revision mismatch makes every native provider session stale. The
        # durable arc history remains available, while this replacement starts
        # with no resume handles from the incompatible process.
        case fence_stale_ticks(agent_id, desired, state) do
          :wait ->
            pending = %{pending | provider: desired.provider, phase: :fencing}
            {:pending, put_pending(state, agent_id, pending)}

          :ok ->
            start_with_latest_config(agent_id, desired, pending, state)

          {:error, reason} ->
            {{:error, {:fence_stale_ticks, reason}}, state}
        end
    end
  end

  defp start_with_latest_config(agent_id, desired, pending, state) do
    case invoke(state, :seed_map, [desired.routine]) do
      seeds when is_map(seeds) ->
        config = invoke(state, :agent_config, [desired.routine, seeds])

        case invoke(state, :start_agent, [agent_id, desired.provider, config]) do
          {:ok, _pid} ->
            finish_start(agent_id, desired, pending, state)

          :ok ->
            finish_start(agent_id, desired, pending, state)

          {:error, {:already_started, _pid}} ->
            finish_existing_start(agent_id, desired, pending, state)

          {:error, reason} ->
            {{:error, {:start_agent, reason}}, state}

          other ->
            {{:error, {:start_agent, other}}, state}
        end

      {:error, reason} ->
        {{:error, {:seed_map, reason}}, state}

      other ->
        {{:error, {:seed_map, {:unexpected_reply, other}}}, state}
    end
  end

  defp start_after_physical_boundary(agent_id, pending, state) do
    case invoke(state, :active_turn?, [agent_id]) do
      true ->
        pending = %{pending | phase: :physical_wait}
        {:pending, put_pending(state, agent_id, pending)}

      false ->
        start_latest(agent_id, pending, state)

      {:error, reason} ->
        {{:error, {:active_turn, reason}}, put_pending(state, agent_id, pending)}

      other ->
        {{:error, {:active_turn, {:unexpected_reply, other}}},
         put_pending(state, agent_id, pending)}
    end
  end

  defp finish_existing_start(agent_id, desired, pending, state) do
    desired_provider = desired.provider

    with {:ok, ^desired_provider} <- invoke(state, :live_provider, [agent_id]),
         {:ok, info} <- invoke(state, :info, [agent_id, desired.provider]),
         true <- compatible?(desired.provider, info, desired) do
      finish_start(agent_id, desired, pending, state)
    else
      false -> {{:error, :already_started_with_stale_configuration}, state}
      {:error, reason} -> {{:error, {:already_started, reason}}, state}
      other -> {{:error, {:already_started, other}}, state}
    end
  end

  defp finish_start(agent_id, started, pending, state) do
    pending = %{pending | provider: started.provider}
    state = put_pending(state, agent_id, pending)

    case desired(agent_id, state) do
      {:ok, current}
      when current.provider == started.provider and current.revision == started.revision ->
        if pending.preserve_pause? do
          preserve_pause(agent_id, started.provider, state)
        else
          # Do not replay inside the ensure/1 call that may itself be the
          # delivery callback for a newly inserted durable message. Leave the
          # fence closed until a later mailbox turn, after that caller has
          # recorded its row as queued, then replay every row exactly once.
          pending = %{pending | phase: :replaying}
          state = put_pending(state, agent_id, pending)
          {:pending, state}
        end

      {:ok, _changed_again} ->
        # The roster changed during the stop/start window. Do not expose the
        # intermediate config or replay queued work; quiesce it on the next
        # coordinator pass, which refetches the newest desired contract.
        pending = %{pending | phase: :quiescing}
        state = put_pending(state, agent_id, pending)

        case invoke(state, :info, [agent_id, started.provider]) do
          {:ok, info} -> begin_handoff(agent_id, started.provider, info, state)
          _missing -> {:pending, state}
        end

      {:error, :unknown_routine} ->
        _ = invoke(state, :stop_agent, [agent_id, started.provider])
        forget_removed(agent_id, state)
    end
  end

  defp preserve_pause(agent_id, provider, state) do
    pending = %{
      provider: provider,
      preserve_pause?: true,
      phase: :preserving
    }

    state = put_pending(state, agent_id, pending)

    case pause_intent(agent_id, state) do
      {:ok, context} when is_map(context) ->
        apply_preserved_pause(agent_id, provider, context, state)

      {:ok, nil} ->
        {{:error, {:preserve_pause, :missing_pause_intent}}, state}

      {:error, reason} ->
        {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp apply_preserved_pause(agent_id, provider, context, state) do
    context = provider_pause_context(context)

    case invoke(state, :emergency_pause, [agent_id, provider, context]) do
      :ok ->
        case invoke(state, :await, [agent_id, provider, :paused, state.stop_timeout]) do
          {:ok, _paused} ->
            finish_preserving(agent_id, provider, state)

          {:error, reason} ->
            {{:error, {:preserve_pause, reason}}, state}

          other ->
            {{:error, {:preserve_pause, other}}, state}
        end

      {:error, reason} ->
        {{:error, {:preserve_pause, reason}}, state}

      other ->
        {{:error, {:preserve_pause, other}}, state}
    end
  end

  # Ecto's map type durably encodes atom values as JSON strings. Restore the
  # finite provenance enum before handing the context back to a provider so
  # transition consumers see the same cause before and after a replacement.
  # Reasons remain strings because rail reasons are intentionally free-form.
  defp provider_pause_context(context) do
    case value(context, :cause) do
      "pause_after_turn" -> put_pause_cause(context, :pause_after_turn)
      "quiesce" -> put_pause_cause(context, :quiesce)
      "emergency_pause" -> put_pause_cause(context, :emergency_pause)
      "preexisting_pause" -> put_pause_cause(context, :preexisting_pause)
      _atom_or_unknown -> context
    end
  end

  defp put_pause_cause(context, cause) do
    context
    |> Map.delete("cause")
    |> Map.put(:cause, cause)
  end

  defp finish_preserving(agent_id, provider, state) do
    case clear_pause_intent(agent_id, state) do
      :ok -> preserve_replay_fence(agent_id, provider, state)
      {:error, reason} -> {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp deferred_pause_pending?(info) do
    case value(info, :deferred_pause) do
      context when is_map(context) -> not config_change?(context)
      _none -> false
    end
  end

  defp config_change_pause?(info) do
    config_change?(value(info, :pause_context)) or
      config_change?(value(info, :deferred_pause))
  end

  defp preserve_replay_fence(agent_id, provider, state) do
    if invoke(state, :queued?, [agent_id]) do
      pending = %{
        provider: provider,
        preserve_pause?: true,
        phase: :preserved
      }

      {:paused, put_pending(state, agent_id, pending)}
    else
      {:paused, delete_pending(state, agent_id)}
    end
  end

  defp finish_reverted_handoff(agent_id, %{preserve_pause?: true} = pending, state) do
    case clear_pause_intent(agent_id, state) do
      :ok -> preserve_replay_fence(agent_id, pending.provider, state)
      {:error, reason} -> {{:error, {:pause_intent, reason}}, state}
    end
  end

  defp finish_reverted_handoff(agent_id, pending, state) do
    case invoke(state, :resume_agent, [agent_id, pending.provider]) do
      result when result in [:resumed, :ok] ->
        if invoke(state, :queued?, [agent_id]) do
          pending = %{pending | phase: :replaying}
          {:pending, put_pending(state, agent_id, pending)}
        else
          {:ready, delete_pending(state, agent_id)}
        end

      {:error, reason} ->
        {{:error, {:resume_reverted, reason}}, state}

      other ->
        {{:error, {:resume_reverted, other}}, state}
    end
  end

  defp replay(agent_id, _pending, state) do
    case invoke(state, :replay_next, [agent_id]) do
      :empty ->
        finish_empty_replay(agent_id, state)

      {:accepted, _message_id} ->
        pending = Map.fetch!(state.pending, agent_id)
        {:pending, put_pending(state, agent_id, %{pending | phase: :draining})}

      {:deferred, _reason} ->
        {:pending, state}

      {:error, reason} ->
        {{:error, {:replay_queued, reason}}, state}

      other ->
        {{:error, {:replay_queued, {:unexpected_reply, other}}}, state}
    end
  end

  defp finish_empty_replay(agent_id, state) do
    case classify_replay(invoke(state, :release_inbox, [agent_id])) do
      :ok -> {:ready, delete_pending(state, agent_id)}
      {:error, reason} -> {{:error, {:release_inbox, reason}}, state}
    end
  end

  defp classify_replay(:ok), do: :ok
  defp classify_replay({:ok, _result}), do: :ok
  defp classify_replay({:error, reason}), do: {:error, reason}
  defp classify_replay(other), do: {:error, {:unexpected_reply, other}}

  defp stop_and_wait(agent_id, provider, state) do
    case invoke(state, :stop_agent, [agent_id, provider]) do
      :ok -> await_offline(agent_id, provider, state)
      {:error, :agent_not_running} -> :ok
      {:error, reason} -> {:error, {:stop_agent, reason}}
      other -> {:error, {:stop_agent, other}}
    end
  end

  defp await_offline(agent_id, provider, state) do
    case invoke(state, :await, [agent_id, provider, :offline, state.stop_timeout]) do
      {:ok, _offline} -> :ok
      {:error, reason} -> {:error, {:await_offline, reason}}
      other -> {:error, {:await_offline, other}}
    end
  end

  defp desired(agent_id, state) do
    case invoke(state, :routine_get, [agent_id]) do
      nil ->
        {:error, :unknown_routine}

      {:error, reason} ->
        {:error, {:routine_get, reason}}

      routine when is_map(routine) ->
        revision = invoke(state, :execution_revision, [routine])

        case snapshot_authorization(routine, revision, state) do
          :ok ->
            {:ok,
             %{
               routine: routine,
               provider: value(routine, :provider),
               revision: revision,
               delivery_revision: invoke(state, :delivery_revision, [routine])
             }}

          {:error, reason} ->
            {:error, {:authorization_snapshot, reason}}
        end

      other ->
        {:error, {:routine_get, {:unexpected_reply, other}}}
    end
  end

  defp compatible?(provider, info, desired) do
    provider == desired.provider and value(info, :config_revision) == desired.revision
  end

  defp existing_non_config_pause?(info), do: is_map(non_config_pause_context(info))

  defp non_config_pause_context(info) do
    state = value(info, :state)
    latch = value(info, :deferred_pause)
    pause_context = value(info, :pause_context)

    cond do
      is_map(pause_context) -> if(config_change?(pause_context), do: nil, else: pause_context)
      is_map(latch) -> if(config_change?(latch), do: nil, else: latch)
      state == :paused -> %{cause: :preexisting_pause, reason: :unknown}
      true -> nil
    end
  end

  defp preserved_pause_context(agent_id, info, state) do
    case pause_intent(agent_id, state) do
      {:ok, stored} ->
        persist_pause_context(agent_id, stored || non_config_pause_context(info), state)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_pause_context(_agent_id, nil, _state), do: {:ok, nil}

  defp persist_pause_context(agent_id, context, state) do
    case invoke(state, :put_pause_intent, [agent_id, context]) do
      :ok -> {:ok, context}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp pause_intent(agent_id, state) do
    case invoke(state, :pause_intent, [agent_id]) do
      nil -> {:ok, nil}
      context when is_map(context) -> {:ok, context}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp clear_pause_intent(agent_id, state) do
    case invoke(state, :clear_pause_intent, [agent_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp forget_removed(agent_id, state, settle_messages? \\ false) do
    with :ok <- maybe_settle_removed_messages(agent_id, settle_messages?, state),
         {:ok, pause_context} <- pause_intent(agent_id, state),
         :ok <- maybe_clear_pause_intent(agent_id, pause_context, state) do
      {:ready, delete_pending(state, agent_id)}
    else
      {:error, {:settle_removed_messages, reason}} ->
        {{:error, {:settle_removed_messages, reason}},
         retain_removal_cleanup(agent_id, state, settle_messages?)}

      {:error, reason} ->
        {{:error, {:pause_intent, reason}},
         retain_removal_cleanup(agent_id, state, settle_messages?)}
    end
  end

  defp retain_removal_cleanup(_agent_id, state, false), do: state

  defp retain_removal_cleanup(agent_id, state, true) do
    pending =
      state.pending
      |> Map.get(agent_id, %{})
      |> Map.put(:phase, :removal_cleanup)
      |> Map.put(:preserve_pause?, false)

    put_pending(state, agent_id, pending)
  end

  defp maybe_settle_removed_messages(_agent_id, false, _state), do: :ok

  defp maybe_settle_removed_messages(agent_id, true, state),
    do: settle_removed_messages(agent_id, state)

  defp settle_removed_messages(agent_id, state) do
    case invoke(state, :settle_removed_messages, [agent_id]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:settle_removed_messages, reason}}
      other -> {:error, {:settle_removed_messages, {:unexpected_reply, other}}}
    end
  end

  defp maybe_clear_pause_intent(_agent_id, nil, _state), do: :ok

  defp maybe_clear_pause_intent(agent_id, _context, state),
    do: clear_pause_intent(agent_id, state)

  defp config_change?(latch) when is_map(latch) do
    value(latch, :cause) in [:quiesce, "quiesce"] and
      (value(latch, :reason) in [:config_change, "config_change"] or
         value(latch, :pause_reason) in [:config_change, "config_change"])
  end

  defp config_change?(_latch), do: false

  defp state_of({state, _payload}) when is_atom(state), do: state
  defp state_of(state) when is_atom(state), do: state
  defp state_of(_unknown), do: :unknown

  defp value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, to_string(key), default))
  end

  defp put_pending(state, agent_id, pending) do
    %{state | pending: Map.put(state.pending, agent_id, pending)}
  end

  defp delete_pending(state, agent_id) do
    %{state | pending: Map.delete(state.pending, agent_id)}
  end

  defp schedule_poll(%{pending: pending, poll_timer: nil} = state)
       when map_size(pending) > 0 do
    ref = Process.send_after(self(), :poll_pending, state.poll_interval)
    %{state | poll_timer: ref}
  end

  defp schedule_poll(state), do: state

  defp boot_reconcile(state) do
    with routines when is_list(routines) <- invoke(state, :routine_all, []),
         :ok <- settle_absent_message_targets(routines, state),
         :ok <- boot_step(:messages, invoke(state, :reconcile_messages, [])),
         :ok <-
           boot_step(
             :pause_intents,
             invoke(state, :clear_absent_pause_intents, [Enum.map(routines, &value(&1, :id))])
           ),
         :ok <- snapshot_authorizations(routines, state),
         {:ok, state} <- reconcile_routines(routines, state) do
      {:ok, state}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:routine_all, {:unexpected_reply, other}}}
    end
  end

  defp settle_absent_message_targets(routines, state) do
    configured_ids = routines |> Enum.map(&value(&1, :id)) |> MapSet.new()

    case invoke(state, :active_message_target_ids, []) do
      target_ids when is_list(target_ids) ->
        target_ids
        |> Enum.reject(&MapSet.member?(configured_ids, &1))
        |> Enum.reduce_while(:ok, &settle_absent_message_target(&1, state, &2))

      {:error, reason} ->
        {:error, {:removed_message_targets, reason}}

      other ->
        {:error, {:removed_message_targets, {:unexpected_reply, other}}}
    end
  end

  defp settle_absent_message_target(agent_id, state, :ok) do
    case settle_removed_messages(agent_id, state) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, {:removed_messages, agent_id, reason}}}
    end
  end

  defp boot_step(_step, :ok), do: :ok
  defp boot_step(step, {:error, reason}), do: {:error, {step, reason}}
  defp boot_step(step, other), do: {:error, {step, {:unexpected_reply, other}}}

  defp snapshot_current_authorizations(state) do
    case invoke(state, :routine_all, []) do
      routines when is_list(routines) -> snapshot_authorizations(routines, state)
      {:error, reason} -> {:error, {:routine_all, reason}}
      other -> {:error, {:routine_all, {:unexpected_reply, other}}}
    end
  end

  defp snapshot_authorizations(routines, state) do
    Enum.reduce_while(routines, :ok, fn routine, :ok ->
      revision = invoke(state, :execution_revision, [routine])

      case snapshot_authorization(routine, revision, state) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp snapshot_authorization(routine, revision, state)
       when is_map(routine) and is_binary(revision) and revision != "" do
    case invoke(state, :authorization_put, [routine, revision]) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp snapshot_authorization(routine, revision, _state) do
    {:error, {:invalid_execution_revision, value(routine, :id), revision}}
  end

  defp reconcile_routines(routines, state) do
    Enum.reduce_while(routines, {:ok, state}, &reconcile_routine/2)
  end

  defp reconcile_routine(routine, {:ok, state}) do
    case value(routine, :id) do
      agent_id when is_binary(agent_id) -> reconcile_routine_id(agent_id, state)
      _invalid -> {:halt, {:error, {:routine, :invalid_id}}}
    end
  end

  defp reconcile_routine_id(agent_id, state) do
    case reconcile_one(agent_id, state) do
      {{:error, reason}, _state} ->
        {:halt, {:error, {:routine, agent_id, reason}}}

      {result, state} ->
        {:cont, {:ok, recover_replay(agent_id, result, state)}}
    end
  end

  defp activate_replay(agent_id, state) do
    {result, state} = reconcile_one(agent_id, state)

    cond do
      Map.has_key?(state.pending, agent_id) ->
        {result, state}

      not invoke(state, :queued?, [agent_id]) ->
        {result, state}

      true ->
        activate_queued_replay(agent_id, result, state)
    end
  end

  defp activate_queued_replay(agent_id, result, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> start_replay_activation(agent_id, result, desired, state)
      {:error, :unknown_routine} -> {result, state}
    end
  end

  defp start_replay_activation(agent_id, result, desired, state) do
    pending = %{
      provider: desired.provider,
      preserve_pause?: result == :paused,
      phase: if(result == :paused, do: :preserved, else: :replaying)
    }

    state = put_pending(state, agent_id, pending)

    if pending.phase == :preserved,
      do: {:paused, state},
      else: advance_replay_owner(agent_id, desired, pending, state)
  end

  # If the coordinator died after starting a compatible replacement but
  # before replay, revision comparison alone cannot reconstruct that phase.
  # Briefly close the boot fence around every compatible, live, non-paused
  # routine. The replay pass is a no-op when no durable messages are queued.
  defp recover_replay(agent_id, result, state) when result in [:ready, :paused] do
    if Map.has_key?(state.pending, agent_id) do
      state
    else
      recover_unowned_replay(agent_id, result, state)
    end
  end

  defp recover_replay(_agent_id, _result, state), do: state

  defp recover_unowned_replay(agent_id, result, state) do
    case invoke(state, :live_provider, [agent_id]) do
      {:ok, provider} -> recover_live_replay(agent_id, provider, result, state)
      :offline -> recover_offline_replay(agent_id, state)
      _invalid -> state
    end
  end

  defp recover_offline_replay(agent_id, state) do
    if invoke(state, :queued?, [agent_id]),
      do: recover_queued_offline_replay(agent_id, state),
      else: state
  end

  defp recover_queued_offline_replay(agent_id, state) do
    case desired(agent_id, state) do
      {:ok, desired} -> start_recovered_offline_replay(agent_id, desired, state)
      _unknown -> state
    end
  end

  defp start_recovered_offline_replay(agent_id, desired, state) do
    pending = %{
      provider: desired.provider,
      preserve_pause?: false,
      phase: :replaying
    }

    {_result, state} =
      start_after_physical_boundary(
        agent_id,
        pending,
        put_pending(state, agent_id, pending)
      )

    state
  end

  defp recover_live_replay(agent_id, provider, result, state) do
    case invoke(state, :status, [agent_id, provider]) do
      {:ok, status} ->
        recover_live_replay_status(agent_id, provider, result, state_of(status), state)

      _offline_paused_or_unavailable ->
        state
    end
  end

  defp recover_live_replay_status(agent_id, provider, :paused, :paused, state) do
    if invoke(state, :queued?, [agent_id]) do
      put_pending(state, agent_id, %{
        provider: provider,
        preserve_pause?: true,
        phase: :preserved
      })
    else
      state
    end
  end

  defp recover_live_replay_status(_agent_id, _provider, _result, state_name, state)
       when state_name in [:offline, :paused],
       do: state

  defp recover_live_replay_status(agent_id, provider, _result, _state_name, state) do
    put_pending(state, agent_id, %{
      provider: provider,
      preserve_pause?: false,
      phase: :replaying
    })
  end

  defp invoke(state, name, args) do
    state.dependencies |> Map.fetch!(name) |> apply(args)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp invoke_admission(agent_id, fun, opts, state) do
    with :ok <- expected_contract(agent_id, opts, state) do
      invoke_admission(fun)
    end
  end

  defp expected_contract(agent_id, opts, state) do
    contract = {
      Keyword.fetch(opts, :expected_provider),
      Keyword.fetch(opts, :expected_revision),
      Keyword.fetch(opts, :expected_delivery_revision)
    }

    validate_expected_contract(agent_id, contract, state)
  end

  defp validate_expected_contract(_agent_id, {:error, :error, :error}, _state), do: :ok

  defp validate_expected_contract(
         agent_id,
         {{:ok, provider}, :error, {:ok, revision}},
         state
       )
       when provider in [:claude, :codex] and is_binary(revision) and revision != "" do
    expected_delivery_contract(agent_id, provider, revision, state)
  end

  defp validate_expected_contract(
         agent_id,
         {{:ok, provider}, {:ok, revision}, :error},
         state
       )
       when provider in [:claude, :codex] and is_binary(revision) and revision != "" do
    expected_execution_contract(agent_id, provider, revision, state)
  end

  defp validate_expected_contract(_agent_id, _contract, _state),
    do: {:error, :invalid_expected_execution_config}

  defp expected_delivery_contract(agent_id, provider, revision, state) do
    case desired(agent_id, state) do
      {:ok, %{provider: ^provider, delivery_revision: ^revision}} ->
        :ok

      {:ok, current} ->
        {:error,
         {:stale_execution_config,
          %{expected_provider: provider, expected_delivery_revision: revision},
          %{provider: current.provider, delivery_revision: current.delivery_revision}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp expected_execution_contract(agent_id, provider, revision, state) do
    case desired(agent_id, state) do
      {:ok, %{provider: ^provider, revision: ^revision}} ->
        :ok

      {:ok, current} ->
        {:error,
         {:stale_execution_config, %{expected_provider: provider, expected_revision: revision},
          %{provider: current.provider, revision: current.revision}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp invoke_admission(fun) do
    fun.()
  rescue
    exception -> {:error, {:admission_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:admission_throw, kind, reason}}
  end

  defp continuation_ready?(agent_id, state) do
    with {:ok, provider} <- invoke(state, :live_provider, [agent_id]),
         {:ok, status} <- invoke(state, :status, [agent_id, provider]) do
      state_of(status) == :waiting_for_user
    else
      _not_waiting -> false
    end
  end

  defp fence_stale_ticks(agent_id, desired, state) do
    case invoke(state, :fence_stale_ticks, [agent_id, desired.provider, desired.delivery_revision]) do
      {:ok, %{executing: []}} -> :ok
      {:ok, %{executing: [_ | _]}} -> :wait
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_reply, other}}
    end
  end

  defp dependencies(opts) do
    defaults = %{
      routine_all: &Routine.all/0,
      routine_get: &Routine.get/1,
      routine_role: &Routine.role/1,
      execution_revision: &Routine.execution_revision/1,
      delivery_revision: &Routine.delivery_revision/1,
      seed_map: &ConversationArcs.seed_map/1,
      agent_config: &Routine.agent_config/2,
      live_provider: &Agents.live_provider/1,
      info: &Agents.info/2,
      status: &Agents.status/2,
      quiesce: &Agents.quiesce/3,
      stop_agent: &Agents.stop_agent/2,
      await: &Agents.await/4,
      start_agent: &Agents.start_agent/3,
      emergency_pause: &Agents.emergency_pause/3,
      resume_agent: &Agents.resume_agent/2,
      active_turn?: &ProviderJobs.active_turn?/1,
      active_turns: &ProviderJobs.active_turns/1,
      authorization_get: &AgentAuthorizationSnapshot.get/2,
      authorization_put: &AgentAuthorizationSnapshot.put/2,
      fence_stale_ticks: &ProviderJobs.fence_stale_ticks/3,
      pause_intent: &AgentHandoffIntent.get/1,
      put_pause_intent: &AgentHandoffIntent.put/2,
      clear_pause_intent: &AgentHandoffIntent.clear/1,
      clear_absent_pause_intents: &AgentHandoffIntent.clear_absent/1,
      defer_unstarted: &OperatorMessages.defer_unstarted/1,
      active_message_target_ids: &OperatorMessages.active_target_ids/0,
      settle_removed_messages: &OperatorMessages.settle_removed/1,
      reconcile_messages: &OperatorMessages.reconcile!/0,
      queued?: fn agent_id ->
        OperatorMessages.queued_for(agent_id) != [] or
          match?(
            %{state: "pending", blocked_by: "config_transition"},
            InboxWakes.get(agent_id)
          )
      end,
      replay_next: &Actions.replay_next/1,
      release_inbox: &InboxWakes.config_ready/1
    }

    Map.merge(defaults, Map.new(Keyword.get(opts, :dependencies, %{})))
  end
end
