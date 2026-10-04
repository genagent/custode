defmodule Custode.InboxWakes do
  @moduledoc """
  Durable, coalesced delivery of inbox activity.

  One row is retained per routine until delivery claims a debounce-complete
  wave. Notes before that cutoff join its stable `wake_id`; later notes create
  the next wave, which the captured delivery task cannot clear or release.
  Oban jobs are only kickoffs. The row and claim token decide whether delivery
  may run.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Custode.{
    AgentHandoff,
    AgentHandoffIntent,
    Agents,
    ConversationArcs,
    InboxWake,
    InboxWakeJob,
    Repo,
    Routine,
    SpendLedger
  }

  @debounce_seconds 20
  @retry_seconds 5
  @max_delivery_retries 1
  @reason "inbox_activity"
  @provider_job_states ~w(available scheduled executing retryable suspended)
  @admitted_provider_job_states @provider_job_states ++ ["completed"]
  @provider_job_workers ~w(ObanClaude.Agent.Job ObanCodex.Agent.Job)
  @held_blockers ~w(running paused spend_rail waiting_for_user awaiting_permission provider_job delivery_failed)
  @handler_id "custode-inbox-wakes"
  @events [
    [:oban_claude, :agent, :transition],
    [:oban_codex, :agent, :transition],
    [:oban, :job, :stop],
    [:oban, :job, :exception]
  ]

  defmodule Monitor do
    @moduledoc false

    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

    def watch(routine_id, provider, wake \\ nil),
      do: GenServer.call(__MODULE__, {:watch, routine_id, provider, identity(wake)})

    def unwatch(routine_id, wake_id, claim_token),
      do: GenServer.cast(__MODULE__, {:unwatch, routine_id, wake_id, claim_token})

    def unwatch_wave(routine_id, wake_id),
      do: GenServer.cast(__MODULE__, {:unwatch_wave, routine_id, wake_id})

    def recover(routine_id, wake_id, claim_token),
      do: GenServer.cast(__MODULE__, {:recover, routine_id, wake_id, claim_token})

    @impl GenServer
    def init(state), do: {:ok, state}

    @impl GenServer
    def handle_call({:watch, routine_id, provider, {wake_id, claim_token}}, _from, state) do
      state = drop_watch(state, routine_id)

      case Registry.lookup(registry(provider), routine_id) do
        [{pid, _value}] ->
          ref = Process.monitor(pid)
          {:reply, :ok, Map.put(state, routine_id, {ref, pid, wake_id, claim_token})}

        [] ->
          recover_async(routine_id, wake_id, claim_token)
          {:reply, :ok, state}
      end
    end

    @impl GenServer
    def handle_cast({:unwatch, routine_id, wake_id, claim_token}, state) do
      case Map.get(state, routine_id) do
        {_ref, _pid, ^wake_id, ^claim_token} -> {:noreply, drop_watch(state, routine_id)}
        _other -> {:noreply, state}
      end
    end

    def handle_cast({:unwatch_wave, routine_id, wake_id}, state) do
      case Map.get(state, routine_id) do
        {_ref, _pid, ^wake_id, _claim_token} -> {:noreply, drop_watch(state, routine_id)}
        _other -> {:noreply, state}
      end
    end

    def handle_cast({:recover, routine_id, wake_id, claim_token}, state) do
      recover_async(routine_id, wake_id, claim_token)
      {:noreply, state}
    end

    @impl GenServer
    def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
      case Enum.find(state, fn {_routine_id, {known_ref, _pid, _wake_id, _claim_token}} ->
             known_ref == ref
           end) do
        {routine_id, {_ref, _pid, wake_id, claim_token}} ->
          recover_async(routine_id, wake_id, claim_token)
          {:noreply, Map.delete(state, routine_id)}

        nil ->
          {:noreply, state}
      end
    end

    defp drop_watch(state, routine_id) do
      case Map.pop(state, routine_id) do
        {{ref, _pid, _wake_id, _claim_token}, state} ->
          Process.demonitor(ref, [:flush])
          state

        {nil, state} ->
          state
      end
    end

    defp registry(:claude), do: ObanClaude.Agent.Registry
    defp registry(:codex), do: ObanCodex.Agent.Registry

    defp recover_async(routine_id, wake_id, claim_token) do
      Task.Supervisor.start_child(Custode.TaskSupervisor, fn ->
        Custode.InboxWakes.provider_down(routine_id, wake_id, claim_token)
      end)

      :ok
    end

    defp identity(%Custode.InboxWake{wake_id: wake_id, claim_token: claim_token}),
      do: {wake_id, claim_token}

    defp identity(_wake), do: {nil, nil}
  end

  defmodule BootReconciler do
    @moduledoc false

    @doc false
    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]},
        restart: :temporary,
        type: :worker
      }
    end

    # The supervisor does not advance to MCP.Probe (which starts :ticks)
    # until this returns. A Task child would return from start_link before its
    # body ran and could reset a claim made by a new kickoff.
    @doc false
    def start_link(_opts) do
      # Budget authority is restored first. A pre-restart one-wake override
      # remains recorded, but the replacement process is conservatively
      # paused until the operator explicitly resumes it again.
      pause = &Custode.SpendLedger.restore_boot_pause!/1
      Custode.SpendLedger.reconcile_pauses!(pause: pause)
      Custode.InboxWakes.reconcile!(pause: pause)
      :ignore
    end
  end

  @doc """
  Add inbox activity to a routine's current wave and move its debounce window
  to `debounce_seconds` after this note.
  """
  @spec request(map() | String.t(), keyword()) ::
          {:ok, InboxWake.t()} | {:error, :unknown_routine | :ignored | term()}
  def request(routine_or_id, opts \\ []) do
    with {:ok, routine} <- fetch_routine(routine_or_id),
         :ok <- accepts_wakes(routine) do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> with_usec()
      debounce_seconds = Keyword.get(opts, :debounce_seconds, @debounce_seconds)
      due_at = DateTime.add(now, debounce_seconds, :second)

      result =
        Repo.transaction(
          fn -> upsert_wave(routine, now, due_at) end,
          mode: :immediate
        )

      case result do
        {:ok, wake} ->
          schedule_wave(wake, now)
          broadcast(routine.id)
          {:ok, wake}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Add a wave and its kickoff inside the caller's transaction. No monitor or
  PubSub work runs until the caller invokes `notify_committed/1` after commit.
  An enqueue failure rolls back the entire caller transaction.
  """
  def request_in_transaction(routine_or_id, opts \\ []) do
    unless Repo.in_transaction?(), do: raise(ArgumentError, "a transaction is required")

    with {:ok, routine} <- fetch_routine(routine_or_id),
         :ok <- accepts_wakes(routine) do
      now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> with_usec()
      due_at = DateTime.add(now, Keyword.get(opts, :debounce_seconds, @debounce_seconds), :second)
      wake = upsert_wave(routine, now, due_at)
      enqueue = Keyword.get(opts, :enqueue, &insert_kickoff(&1, now))

      enqueue_in_transaction(wake, enqueue)
      {:ok, wake}
    end
  end

  defp enqueue_in_transaction(%{blocked_by: blocker}, _enqueue) when blocker in @held_blockers,
    do: :ok

  defp enqueue_in_transaction(wake, enqueue) do
    case enqueue.(wake) do
      :ok -> :ok
      {:error, reason} -> Repo.rollback({:wake_enqueue_failed, reason})
      other -> Repo.rollback({:unexpected_wake_enqueue_reply, other})
    end
  end

  @doc "Publish a committed wave and restore monitors for any retained hold."
  def notify_committed(%InboxWake{} = observed) do
    case get(observed.routine_id) do
      %InboxWake{wake_id: wake_id} = current when wake_id == observed.wake_id ->
        retain_hold(current)
        broadcast(current.routine_id)

      _other ->
        :ok
    end
  end

  def notify_committed(nil), do: :ok

  @doc "One routine's durable wake row, or `nil`."
  @spec get(String.t()) :: InboxWake.t() | nil
  def get(routine_id) when is_binary(routine_id), do: Repo.get(InboxWake, routine_id)

  @doc "A stable read model for operator surfaces, or `nil` when no wake is pending."
  @spec read_model(String.t()) :: map() | nil
  def read_model(routine_id) when is_binary(routine_id) do
    case get(routine_id) do
      nil ->
        nil

      wake ->
        Map.take(wake, [
          :wake_id,
          :reason,
          :state,
          :note_count,
          :first_note_at,
          :last_note_at,
          :due_at,
          :blocked_by,
          :spend_override,
          :claimed_at
        ])
    end
  end

  @doc false
  def config_ready(routine_id, opts \\ []) when is_binary(routine_id) do
    now = with_usec(DateTime.utc_now())
    transaction = Keyword.get(opts, :transaction, &config_ready_transaction/1)
    enqueue = Keyword.get(opts, :enqueue, &insert_kickoff(&1, now))

    result =
      transaction.(fn ->
        case Repo.get(InboxWake, routine_id) do
          %InboxWake{state: "pending", blocked_by: "config_transition"} = wake ->
            release_config_wake(wake, enqueue)

          _other ->
            nil
        end
      end)

    case result do
      {:ok, %InboxWake{}} ->
        broadcast(routine_id)
        :ok

      {:ok, nil} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected_transaction_reply, other}}
    end
  rescue
    exception -> {:error, {:config_ready_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:config_ready_throw, kind, reason}}
  end

  defp config_ready_transaction(fun), do: Repo.transaction(fun, mode: :immediate)

  defp release_config_wake(wake, enqueue) do
    case enqueue.(wake) do
      :ok ->
        wake
        |> InboxWake.update_changeset(%{blocked_by: nil, retry_count: 0})
        |> Repo.update()
        |> case do
          {:ok, released} -> released
          {:error, changeset} -> Repo.rollback({:persist_failed, changeset})
        end

      {:error, reason} ->
        Repo.rollback({:enqueue_failed, reason})

      other ->
        Repo.rollback({:unexpected_enqueue_reply, other})
    end
  end

  @doc "Attach the provider-neutral transition handler."
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Recover claims whose supervised delivery tasks died with the previous
  application instance, then recreate the unique kickoff for every live wave.
  """
  def reconcile!(opts \\ []) do
    now = with_usec(DateTime.utc_now())
    pause = Keyword.get(opts, :pause, &boot_paused/1)

    Repo.update_all(
      from(w in InboxWake, where: w.state == "dispatching"),
      set: [
        state: "pending",
        claim_token: nil,
        claimed_at: nil,
        blocked_by: nil,
        updated_at: now
      ]
    )

    InboxWake
    |> Repo.all()
    |> Enum.each(&reconcile_wake(&1, now, pause))

    :ok
  end

  @doc false
  def dispatch(routine_id, wake_id, opts \\ [])
      when is_binary(routine_id) and is_binary(wake_id) do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> with_usec()

    case {get(routine_id), Routine.get(routine_id)} do
      {nil, _routine} ->
        :ok

      {%InboxWake{wake_id: other}, _routine} when other != wake_id ->
        :ok

      {%InboxWake{}, nil} ->
        supersede(routine_id, wake_id, :routine_removed)

      {%InboxWake{}, %{on_note: :ignore}} ->
        supersede(routine_id, wake_id, :policy_changed)

      {%InboxWake{} = wake, routine} ->
        dispatch_live(wake, routine, now, opts)
    end
  end

  @doc false
  def handle_event(_event, _measurements, %{agent_id: routine_id, to: :running} = meta, _config) do
    case parse_correlation(Map.get(meta, :correlation_id)) do
      {:ok, wake_id, claim_token} -> clear_claim(routine_id, wake_id, claim_token)
      :error -> update_blocked(routine_id, "running")
    end
  rescue
    exception -> handler_error(exception)
  end

  def handle_event(
        _event,
        _measurements,
        %{agent_id: routine_id, from: from, to: to},
        _config
      )
      when to in [:idle, :waiting_for_user, :awaiting_permission, :paused] do
    if to == :idle do
      release_blocker(routine_id, from == :paused)
    else
      update_blocked(routine_id, Atom.to_string(to))
    end

    :ok
  rescue
    exception -> handler_error(exception)
  end

  def handle_event(
        [:oban, :job, outcome],
        _measurements,
        %{job: %Oban.Job{worker: worker, meta: %{"agent_id" => routine_id}}},
        _config
      )
      when outcome in [:stop, :exception] and worker in @provider_job_workers do
    wake_after_provider_job(routine_id)
  rescue
    exception -> handler_error(exception)
  end

  def handle_event(_event, _measurements, _meta, _config), do: :ok

  @doc false
  def provider_down(routine_id, wake_id \\ nil, claim_token \\ nil) do
    case get(routine_id) do
      %InboxWake{state: "pending"} = wake ->
        if is_nil(wake_id) or wake.wake_id == wake_id do
          # Recovery always crosses the withheld :ticks queue. During boot the
          # Probe starts that queue only after MCP is ready, so a missing
          # provider cannot recreate the first-turn tool blackout.
          ensure_job(wake, with_usec(DateTime.utc_now()))
        else
          :ok
        end

      %InboxWake{
        wake_id: ^wake_id,
        claim_token: ^claim_token,
        state: "dispatching"
      }
      when is_binary(wake_id) and is_binary(claim_token) ->
        release_claim(routine_id, wake_id, claim_token, "offline", true)

      _other ->
        :ok
    end
  rescue
    exception -> handler_error(exception)
  end

  defp upsert_wave(routine, now, due_at) do
    InboxWake
    |> Repo.get(routine.id)
    |> upsert_wave(routine, now, due_at)
  end

  defp upsert_wave(nil, routine, now, due_at), do: create_wave(routine.id, now, due_at)

  defp upsert_wave(wake, routine, now, due_at) do
    provider_work = active_provider_work(routine, wake)

    if replace_wave?(wake, provider_work) do
      replace_wave(wake, routine.id, now, due_at)
    else
      update_wave(wake, routine, provider_work, now, due_at)
    end
  end

  defp replace_wave?(%InboxWake{state: "dispatching"}, _provider_work), do: true
  defp replace_wave?(_wake, :admitted), do: true
  defp replace_wave?(_wake, _provider_work), do: false

  # Claiming is the debounce cutoff. Activity after a claim is a new wave so
  # the captured delivery task cannot clear or release it. A durable
  # correlated provider job is the same boundary after a process crash.
  defp replace_wave(wake, routine_id, now, due_at) do
    Repo.delete!(wake)
    create_wave(routine_id, now, due_at)
  end

  defp update_wave(wake, routine, provider_work, now, due_at) do
    wake
    |> InboxWake.update_changeset(%{
      note_count: wake.note_count + 1,
      last_note_at: now,
      due_at: due_at,
      blocked_by: next_wave_blocker(wake, routine, provider_work),
      retry_count: 0
    })
    |> Repo.update!()
  end

  defp next_wave_blocker(
         %InboxWake{state: "pending", blocked_by: "provider_job"},
         _routine,
         :none
       ),
       do: "debounce"

  defp next_wave_blocker(
         %InboxWake{state: "pending", blocked_by: "delivery_failed"},
         _routine,
         _provider_work
       ),
       do: "debounce"

  defp next_wave_blocker(
         %InboxWake{state: "pending", blocked_by: "running"},
         routine,
         _provider_work
       ) do
    if agent_state(routine.id) == :running, do: "running", else: "debounce"
  end

  defp next_wave_blocker(
         %InboxWake{state: "pending", blocked_by: blocked_by},
         _routine,
         _provider_work
       )
       when blocked_by in [nil, "debounce", "running"],
       do: "debounce"

  defp next_wave_blocker(wake, _routine, _provider_work), do: wake.blocked_by

  defp create_wave(routine_id, now, due_at) do
    %{
      routine_id: routine_id,
      wake_id: Ecto.UUID.generate(),
      state: "pending",
      reason: @reason,
      note_count: 1,
      first_note_at: now,
      last_note_at: now,
      due_at: due_at,
      blocked_by: "debounce"
    }
    |> InboxWake.create_changeset()
    |> Repo.insert!()
  end

  defp dispatch_live(%InboxWake{state: "dispatching"}, _routine, _now, _opts), do: :ok

  defp dispatch_live(wake, routine, now, opts) do
    state = agent_state(routine.id)

    case active_provider_work(routine, wake, state) do
      :admitted -> clear_admitted(wake)
      _provider_work -> dispatch_unadmitted(wake, routine, now, opts, state)
    end
  end

  defp dispatch_unadmitted(
         %InboxWake{blocked_by: "delivery_failed"} = wake,
         _routine,
         _now,
         _opts,
         _state
       ),
       do: hold(wake, "delivery_failed")

  defp dispatch_unadmitted(wake, routine, now, opts, state) do
    case dispatch_authority(wake, routine, state) do
      {:boot_hold, blocked_by} -> boot_and_hold(wake, routine, blocked_by, now)
      {:hold, blocked_by} -> hold(wake, blocked_by)
      :clear -> dispatch_after_authority(wake, routine, now, opts, state)
    end
  end

  defp dispatch_authority(wake, routine, state) do
    cond do
      not wake.spend_override and SpendLedger.over_rail?(routine) ->
        {:boot_hold, "spend_rail"}

      wake.blocked_by == "paused" ->
        {:boot_hold, "paused"}

      state == :paused ->
        {:hold, "paused"}

      true ->
        :clear
    end
  end

  defp boot_and_hold(wake, routine, blocked_by, now) do
    case boot_paused(routine, pause_context(blocked_by)) do
      :ok -> hold(wake, blocked_by)
      {:error, _reason} -> retry_pending(wake, "offline", now)
    end
  end

  defp dispatch_after_authority(wake, routine, now, opts, state) do
    case gate_disposition(routine.id, state) do
      :recovered ->
        release_blocker(routine.id, false)

      {:blocked, reason} ->
        hold_for_gate(wake, routine, reason)

      :none ->
        if DateTime.after?(wake.due_at, now) do
          ensure_job(wake, now)
          :ok
        else
          fence_or_start(wake, routine, now, opts, state)
        end
    end
  end

  # A restarted provider initializes idle even when the old generation's Oban
  # job is still physically running. It may also accept unrelated work before
  # this retry runs, so fence every non-paused state on durable provider work,
  # rather than trusting the replacement process's current state.
  defp fence_or_start(wake, routine, now, opts, state) do
    if state == :running do
      hold(wake, "running")
    else
      case active_provider_work(routine, wake, state) do
        :none ->
          claim_and_start(wake, routine, now, opts, state)

        :blocked ->
          hold_for_provider_job(wake, routine)

        :admitted ->
          clear_admitted(wake)
      end
    end
  end

  defp claim_and_start(wake, routine, now, opts, state) do
    if before_claim = Keyword.get(opts, :before_claim), do: before_claim.()

    case claim(wake, blocked_by(state), now) do
      {:ok, claimed} -> start_delivery(claimed, routine, opts)
      {:not_due, current} -> ensure_job(current, now)
      :already_claimed -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp claim(wake, blocked_by, now) do
    claim_token = Ecto.UUID.generate()

    Repo.transaction(
      fn ->
        claim_current(Repo.get(InboxWake, wake.routine_id), wake, claim_token, blocked_by, now)
      end,
      mode: :immediate
    )
    |> claim_result()
  end

  defp claim_current(
         %InboxWake{wake_id: wake_id, state: "pending"} = current,
         %InboxWake{wake_id: wake_id},
         claim_token,
         blocked_by,
         now
       ) do
    case DateTime.compare(current.due_at, now) do
      :gt -> Repo.rollback({:not_due, current})
      _due -> persist_claim(current, claim_token, blocked_by, now)
    end
  end

  defp claim_current(_current, _wake, _claim_token, _blocked_by, _now),
    do: Repo.rollback(:already_claimed)

  defp persist_claim(current, claim_token, blocked_by, now) do
    current
    |> InboxWake.update_changeset(%{
      state: "dispatching",
      claim_token: claim_token,
      claimed_at: now,
      blocked_by: blocked_by
    })
    |> Repo.update!()
  end

  defp claim_result({:ok, claimed}) do
    broadcast(claimed.routine_id)
    {:ok, claimed}
  end

  defp claim_result({:error, :already_claimed}), do: :already_claimed
  defp claim_result({:error, {:not_due, current}}), do: {:not_due, current}
  defp claim_result({:error, reason}), do: {:error, reason}

  defp start_delivery(wake, routine, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Custode.TaskSupervisor)

    case Task.Supervisor.start_child(supervisor, fn -> deliver(wake, routine) end) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        release_claim(
          routine.id,
          wake.wake_id,
          wake.claim_token,
          blocked_by({:task_start, reason}),
          true
        )

        :ok
    end
  end

  defp deliver(wake, routine) do
    result =
      AgentHandoff.admit(routine.id, fn ->
        with {:ok, current} <- current_delivery_routine(routine.id, wake),
             :ok <- ensure_agent(current, wake),
             :ok <- watch_delivery(current, wake),
             :ok <- delivery_fence(current, wake),
             {:ok, prepared} <-
               ConversationArcs.prepare(current, :inbox, arc_id: "inbox:#{wake.wake_id}") do
          submit(wake, current, prepared)
        end
      end)

    case result do
      :processing ->
        # The synchronous :running telemetry normally cleared this exact
        # claim before submit_prompt replied. A transient projection failure
        # must not strand it until reboot; the durable provider job proves
        # admission, and wake-id matching preserves any later wave.
        clear_admitted(wake)

      :admitted ->
        clear_admitted(wake)

      {:deferred, reason} ->
        release_after_delivery_failure(wake, {:config_transition, reason})
        AgentHandoff.work_queued(wake.routine_id)

      {:error, reason} ->
        release_after_delivery_failure(wake, reason)
    end
  rescue
    exception ->
      release_after_delivery_failure(wake, {:exception, Exception.message(exception)})
  catch
    kind, reason ->
      release_after_delivery_failure(wake, {kind, reason})
  end

  defp current_delivery_routine(routine_id, wake) do
    case Routine.get(routine_id) do
      nil ->
        supersede(routine_id, wake.wake_id, :routine_removed)
        {:error, :superseded}

      %{on_note: :ignore} ->
        supersede(routine_id, wake.wake_id, :policy_changed)
        {:error, :superseded}

      current ->
        {:ok, current}
    end
  end

  defp submit(wake, routine, prepared) do
    result =
      Agents.submit_prompt(routine.id, Routine.tick_prompt(routine),
        origin: :tick,
        session: :fresh,
        arc_id: prepared.arc_id,
        correlation_id: correlation(wake)
      )

    if result != :processing, do: ConversationArcs.abandon(prepared, :delivery_failed)
    result
  end

  defp ensure_agent(routine, wake) do
    if not wake.spend_override and SpendLedger.over_rail?(routine) do
      case boot_paused(routine) do
        :ok -> {:error, :spend_rail}
        {:error, reason} -> {:error, {:start_failed, reason}}
      end
    else
      ensure_agent_state(routine)
    end
  end

  defp ensure_agent_state(routine) do
    case agent_state(routine.id) do
      :offline ->
        seeds = ConversationArcs.seed_map(routine)

        case Agents.start_agent(routine.id, Routine.agent_config(routine, seeds)) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:start_failed, reason}}
        end

      :paused ->
        {:error, :paused}

      _state ->
        :ok
    end
  end

  defp delivery_fence(routine, wake) do
    state = agent_state(routine.id)

    case gate_disposition(routine.id, state) do
      :none -> delivery_fence_without_gate(routine, wake, state)
      {:blocked, blocked_by} -> {:error, {:gate, blocked_by}}
      :recovered -> {:error, :gate_recovered}
    end
  end

  defp delivery_fence_without_gate(_routine, _wake, :running), do: {:error, :running}

  defp delivery_fence_without_gate(routine, wake, state) do
    routine
    |> active_provider_work(wake, state)
    |> provider_fence_result()
  end

  defp provider_fence_result(:none), do: :ok
  defp provider_fence_result(:blocked), do: {:error, :provider_job}
  defp provider_fence_result(:admitted), do: :admitted

  defp watch_delivery(routine, wake) do
    Monitor.watch(routine.id, routine.provider, wake)
    :ok
  end

  defp gate_disposition(routine_id, state) do
    gates = Custode.Gates.open_gates(routine_id)

    cond do
      gates == [] ->
        :none

      Enum.any?(gates, &live_gate?(&1, state)) ->
        {:blocked, gate_blocker(gates)}

      true ->
        Custode.Gates.recover_open(routine_id)
        :recovered
    end
  end

  defp live_gate?(%{kind: "question"}, :waiting_for_user), do: true
  defp live_gate?(%{kind: "approval"}, :awaiting_permission), do: true
  defp live_gate?(_gate, _state), do: false

  defp gate_blocker(gates) do
    if Enum.any?(gates, &(&1.kind == "question")),
      do: "waiting_for_user",
      else: "awaiting_permission"
  end

  defp boot_paused(routine), do: boot_paused(routine, pause_context("spend_rail"))

  defp boot_paused(routine, context) do
    seeds = ConversationArcs.seed_map(routine)

    # Delivery runs inside AgentHandoff.admit/3. Calling the provider-neutral
    # emergency_pause/1 from here would synchronously call that coordinator
    # from its own process after the provider has already started. Record the
    # safety intent first, then use the provider captured by this admission.
    with :ok <- AgentHandoffIntent.put(routine.id, context),
         :ok <- start_for_pause(routine, seeds),
         :ok <- Agents.emergency_pause(routine.id, routine.provider, context),
         {:ok, :paused} <- Agents.await(routine.id, routine.provider, :paused, 1_000) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, other}
    end
  end

  defp pause_context("spend_rail"),
    do: %{cause: :emergency_pause, reason: :spend_rail}

  defp pause_context("paused"),
    do: %{cause: :emergency_pause, reason: :preexisting_pause}

  defp start_for_pause(routine, seeds) do
    case Agents.start_agent(
           routine.id,
           routine.provider,
           Routine.agent_config(routine, seeds)
         ) do
      {:ok, _pid} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp active_provider_work(routine, wake, state \\ nil) do
    worker = provider_job_worker(routine.provider)

    jobs =
      Repo.all(
        from(j in Oban.Job,
          where: j.worker == ^worker,
          where: fragment("json_extract(?, '$.agent_id') = ?", j.meta, ^routine.id),
          select: {j.state, j.meta}
        )
      )

    active_jobs =
      Enum.filter(jobs, fn {job_state, _meta} -> job_state in @provider_job_states end)

    cond do
      Enum.any?(jobs, fn {job_state, meta} ->
        job_state in @admitted_provider_job_states and wake_job?(meta, wake.wake_id)
      end) ->
        :admitted

      active_jobs == [] ->
        :none

      same_running_generation?(routine.id, state, active_jobs) ->
        :none

      true ->
        :blocked
    end
  end

  defp same_running_generation?(routine_id, :running, jobs) do
    case Agents.info(routine_id) do
      {:ok, %{state: :running, continuation: %{agent_generation: generation}}}
      when is_binary(generation) ->
        Enum.all?(jobs, fn {_state, meta} -> meta["agent_generation"] == generation end)

      _other ->
        false
    end
  end

  defp same_running_generation?(_routine_id, _state, _jobs), do: false

  defp wake_job?(%{"correlation_id" => "inbox:" <> rest}, wake_id),
    do: String.starts_with?(rest, wake_id <> ":")

  defp wake_job?(_meta, _wake_id), do: false

  defp provider_job_worker(:claude), do: "ObanClaude.Agent.Job"
  defp provider_job_worker(:codex), do: "ObanCodex.Agent.Job"

  defp release_after_delivery_failure(wake, :paused) do
    release_claim(wake.routine_id, wake.wake_id, wake.claim_token, "paused", false)
  end

  defp release_after_delivery_failure(wake, :spend_rail) do
    release_claim(wake.routine_id, wake.wake_id, wake.claim_token, "spend_rail", false)
  end

  defp release_after_delivery_failure(wake, :provider_job) do
    release_claim(
      wake.routine_id,
      wake.wake_id,
      wake.claim_token,
      "provider_job",
      false
    )

    recheck_provider_hold(wake.routine_id, wake.wake_id)
  end

  defp release_after_delivery_failure(wake, :running) do
    release_claim(wake.routine_id, wake.wake_id, wake.claim_token, "running", false)
  end

  defp release_after_delivery_failure(wake, {:gate, blocked_by}) do
    release_claim(
      wake.routine_id,
      wake.wake_id,
      wake.claim_token,
      blocked_by,
      false
    )

    recheck_gate_hold(wake.routine_id, wake.wake_id)
  end

  defp release_after_delivery_failure(wake, :gate_recovered) do
    release_claim(wake.routine_id, wake.wake_id, wake.claim_token, "debounce", true)
  end

  defp release_after_delivery_failure(wake, {:config_transition, _reason}) do
    release_claim(
      wake.routine_id,
      wake.wake_id,
      wake.claim_token,
      "config_transition",
      false
    )
  end

  defp release_after_delivery_failure(wake, reason) do
    release_claim(
      wake.routine_id,
      wake.wake_id,
      wake.claim_token,
      blocked_by(reason),
      true
    )
  end

  defp release_claim(routine_id, wake_id, claim_token, blocked_by, retry?)
       when is_binary(claim_token) do
    now = with_usec(DateTime.utc_now())

    Repo.transaction(
      fn ->
        routine_id
        |> claimed_wake(wake_id, claim_token)
        |> release_claimed_wake(blocked_by, retry?, now)
      end,
      mode: :immediate
    )
    |> finish_release(routine_id, now)

    :ok
  end

  defp claimed_wake(routine_id, wake_id, claim_token) do
    Repo.one(
      from(w in InboxWake,
        where: w.routine_id == ^routine_id and w.wake_id == ^wake_id,
        where: w.state == "dispatching" and w.claim_token == ^claim_token
      )
    )
  end

  defp release_claimed_wake(nil, _blocked_by, _retry?, _now), do: nil

  defp release_claimed_wake(wake, blocked_by, retry?, now) do
    {attrs, schedule_retry?} = release_attributes(wake, blocked_by, retry?, now)

    updated =
      wake
      |> InboxWake.update_changeset(attrs)
      |> Repo.update!()

    {updated, schedule_retry?}
  end

  defp release_attributes(
         %InboxWake{retry_count: retry_count} = wake,
         blocked_by,
         true,
         now
       )
       when retry_count < @max_delivery_retries do
    retry_at = DateTime.add(now, @retry_seconds, :second)

    attrs =
      release_attributes(wake, blocked_by)
      |> Map.put(:due_at, later_datetime(wake.due_at, retry_at))
      |> Map.put(:retry_count, retry_count + 1)

    {attrs, true}
  end

  defp release_attributes(wake, _blocked_by, true, _now) do
    {release_attributes(wake, "delivery_failed"), false}
  end

  defp release_attributes(wake, blocked_by, false, _now) do
    {release_attributes(wake, blocked_by), false}
  end

  defp release_attributes(wake, blocked_by) do
    %{
      state: "pending",
      claim_token: nil,
      claimed_at: nil,
      blocked_by: blocked_by,
      due_at: wake.due_at,
      retry_count: wake.retry_count
    }
  end

  defp finish_release({:ok, {%InboxWake{} = wake, true}}, routine_id, now) do
    ensure_job(wake, now)
    broadcast(routine_id)
  end

  defp finish_release({:ok, {%InboxWake{} = wake, false}}, routine_id, _now) do
    retain_hold(wake)
    broadcast(routine_id)
  end

  defp finish_release(_result, _routine_id, _now), do: :ok

  defp clear_claim(routine_id, wake_id, claim_token) do
    {count, _rows} =
      Repo.delete_all(
        from(w in InboxWake,
          where:
            w.routine_id == ^routine_id and w.wake_id == ^wake_id and
              w.claim_token == ^claim_token and w.state == "dispatching"
        )
      )

    if count > 0 do
      Monitor.unwatch(routine_id, wake_id, claim_token)
      broadcast(routine_id)
    end

    :ok
  end

  # Recovery exception to claim-token clearing: a durable provider job with
  # this stable wake id proves the prompt was already admitted even if the
  # process died before emitting the matching transition.
  defp clear_admitted(wake) do
    {count, _rows} =
      Repo.delete_all(
        from(w in InboxWake,
          where: w.routine_id == ^wake.routine_id and w.wake_id == ^wake.wake_id
        )
      )

    if count > 0 do
      Monitor.unwatch(wake.routine_id, wake.wake_id, wake.claim_token)
      broadcast(wake.routine_id)
    end

    :ok
  end

  # A provider boot failure gets one delayed retry. If the retry also fails,
  # retain the durable row for a new note or the next application reconcile
  # rather than creating an unbounded polling chain.
  defp retry_pending(%InboxWake{blocked_by: "offline"} = wake, _blocked_by, _now),
    do: hold(wake, "offline")

  defp retry_pending(wake, blocked_by, now) do
    retry_at = DateTime.add(now, @retry_seconds, :second)

    Repo.transaction(
      fn ->
        InboxWake
        |> Repo.get(wake.routine_id)
        |> retry_pending_wave(wake, blocked_by, retry_at)
      end,
      mode: :immediate
    )
    |> finish_pending_retry(now)

    :ok
  end

  defp retry_pending_wave(
         %InboxWake{wake_id: wake_id, state: "pending"} = current,
         %InboxWake{wake_id: wake_id},
         blocked_by,
         retry_at
       ) do
    current
    |> InboxWake.update_changeset(%{
      blocked_by: blocked_by,
      due_at: later_datetime(current.due_at, retry_at)
    })
    |> Repo.update!()
  end

  defp retry_pending_wave(_current, _wake, _blocked_by, _retry_at), do: nil

  defp finish_pending_retry({:ok, %InboxWake{} = held}, now) do
    ensure_job(held, now)
    broadcast(held.routine_id)
  end

  defp finish_pending_retry(_result, _now), do: :ok

  defp hold(wake, blocked_by) do
    {count, _rows} =
      Repo.update_all(
        from(w in InboxWake,
          where: w.routine_id == ^wake.routine_id and w.wake_id == ^wake.wake_id,
          where: w.state == "pending"
        ),
        set: [blocked_by: blocked_by, updated_at: with_usec(DateTime.utc_now())]
      )

    if count > 0 do
      retained = get(wake.routine_id)
      retain_hold(retained)
      broadcast(wake.routine_id)
    end

    :ok
  end

  defp hold_for_provider_job(wake, routine) do
    hold(wake, "provider_job")
    recheck_provider_hold(routine.id, wake.wake_id)
  end

  defp recheck_provider_hold(routine_id, wake_id) do
    with %InboxWake{wake_id: ^wake_id, state: "pending", blocked_by: "provider_job"} = wake <-
           get(routine_id),
         %{id: ^routine_id} = routine <- Routine.get(routine_id) do
      case active_provider_work(routine, wake, agent_state(routine_id)) do
        :none -> release_blocker(routine_id, false)
        :admitted -> clear_admitted(wake)
        :blocked -> :ok
      end
    else
      _other -> :ok
    end
  end

  defp hold_for_gate(wake, routine, blocked_by) do
    hold(wake, blocked_by)
    recheck_gate_hold(routine.id, wake.wake_id)
  end

  defp recheck_gate_hold(routine_id, wake_id) do
    with %InboxWake{wake_id: ^wake_id, state: "pending", blocked_by: blocked_by} <-
           get(routine_id),
         true <- blocked_by in ["waiting_for_user", "awaiting_permission"] do
      case gate_disposition(routine_id, agent_state(routine_id)) do
        {:blocked, _reason} -> :ok
        :none -> release_blocker(routine_id, false)
        :recovered -> release_blocker(routine_id, false)
      end
    else
      _other -> :ok
    end
  end

  defp retain_hold(%InboxWake{} = wake) do
    if wake.blocked_by in ~w(running paused spend_rail waiting_for_user awaiting_permission) do
      case Routine.get(wake.routine_id) do
        %{provider: provider} ->
          Monitor.watch(wake.routine_id, provider, wake)

          unless held_state?(wake.blocked_by, agent_state(wake.routine_id)) do
            Monitor.recover(wake.routine_id, wake.wake_id, wake.claim_token)
          end

        _other ->
          :ok
      end
    end

    :ok
  end

  defp retain_hold(_other), do: :ok

  defp held_state?("paused", :paused), do: true
  defp held_state?("spend_rail", :paused), do: true
  defp held_state?("running", :running), do: true
  defp held_state?("waiting_for_user", :waiting_for_user), do: true
  defp held_state?("awaiting_permission", :awaiting_permission), do: true
  defp held_state?(_blocked_by, _state), do: false

  defp update_blocked(routine_id, blocked_by) do
    query = from(w in InboxWake, where: w.routine_id == ^routine_id)

    query =
      case blocked_by do
        "paused" ->
          from(w in query, where: is_nil(w.blocked_by) or w.blocked_by != "spend_rail")

        blocked when blocked in ["waiting_for_user", "awaiting_permission"] ->
          from(w in query,
            where:
              is_nil(w.blocked_by) or
                w.blocked_by not in ["spend_rail", "paused"]
          )

        "running" ->
          from(w in query,
            where:
              is_nil(w.blocked_by) or
                w.blocked_by in ["debounce", "running", "provider_job", "offline"]
          )

        _other ->
          query
      end

    {count, _rows} =
      Repo.update_all(
        query,
        set: [blocked_by: blocked_by, updated_at: with_usec(DateTime.utc_now())]
      )

    if count > 0, do: broadcast(routine_id)
    :ok
  end

  defp release_blocker(routine_id, spend_override?) do
    now = with_usec(DateTime.utc_now())

    result =
      Repo.transaction(
        fn ->
          case Repo.get(InboxWake, routine_id) do
            %InboxWake{state: "pending"} = wake ->
              routine = Routine.get(routine_id)

              override =
                spend_override? and not is_nil(routine) and SpendLedger.over_rail?(routine)

              wake
              |> InboxWake.update_changeset(%{
                blocked_by: nil,
                spend_override: wake.spend_override or override
              })
              |> Repo.update!()

            _other ->
              nil
          end
        end,
        mode: :immediate
      )

    case result do
      {:ok, %InboxWake{} = wake} ->
        ensure_job(wake, now)
        broadcast(routine_id)

      _other ->
        :ok
    end

    :ok
  end

  defp wake_after_provider_job(routine_id) do
    case get(routine_id) do
      %InboxWake{state: "pending", blocked_by: "provider_job"} = wake ->
        ensure_job(wake, with_usec(DateTime.utc_now()))

      _other ->
        :ok
    end
  end

  defp supersede(routine_id, wake_id, reason) do
    {count, _rows} =
      Repo.delete_all(
        from(w in InboxWake, where: w.routine_id == ^routine_id and w.wake_id == ^wake_id)
      )

    Logger.info("inbox wake #{wake_id} for #{routine_id} superseded: #{reason}")

    if count > 0 do
      Monitor.unwatch_wave(routine_id, wake_id)
      broadcast(routine_id)
    end

    :ok
  end

  defp reconcile_wake(wake, now, pause) do
    wake.routine_id
    |> Routine.get()
    |> reconcile_wake(wake, now, pause)
  end

  defp reconcile_wake(nil, wake, _now, _pause),
    do: supersede(wake.routine_id, wake.wake_id, :routine_removed)

  defp reconcile_wake(%{on_note: :ignore}, wake, _now, _pause),
    do: supersede(wake.routine_id, wake.wake_id, :policy_changed)

  defp reconcile_wake(routine, wake, now, pause) do
    routine
    |> active_provider_work(wake)
    |> reconcile_provider_work(routine, wake, now, pause)
  end

  defp reconcile_provider_work(:admitted, _routine, wake, _now, _pause),
    do: clear_admitted(wake)

  defp reconcile_provider_work(provider_work, routine, wake, now, pause) do
    wake
    |> clear_stale_provider_hold(provider_work)
    |> reset_delivery_failure()
    |> reconcile_authority(routine, now, pause)
  end

  defp reconcile_authority(%InboxWake{spend_override: true} = wake, _routine, now, _pause),
    do: schedule_wave(wake, now)

  defp reconcile_authority(wake, routine, now, pause) do
    if SpendLedger.over_rail?(routine) do
      reconcile_spend_rail(wake, routine, now, pause)
    else
      schedule_wave(wake, now)
    end
  end

  defp reconcile_spend_rail(wake, routine, now, pause) do
    case pause.(routine) do
      :ok -> hold(wake, "spend_rail")
      {:error, _reason} -> retry_pending(wake, "offline", now)
    end
  end

  defp clear_stale_provider_hold(
         %InboxWake{state: "pending", blocked_by: "provider_job"} = wake,
         :none
       ) do
    wake
    |> InboxWake.update_changeset(%{blocked_by: "debounce"})
    |> Repo.update!()
  end

  defp clear_stale_provider_hold(wake, _provider_work), do: wake

  defp reset_delivery_failure(%InboxWake{state: "pending", blocked_by: "delivery_failed"} = wake) do
    wake
    |> InboxWake.update_changeset(%{blocked_by: "debounce", retry_count: 0})
    |> Repo.update!()
  end

  defp reset_delivery_failure(wake), do: wake

  defp schedule_wave(%InboxWake{state: "pending", blocked_by: blocker} = wake, _now)
       when blocker in @held_blockers do
    retain_hold(wake)
  end

  defp schedule_wave(%InboxWake{} = wake, now), do: ensure_job(wake, now)

  defp ensure_job(%InboxWake{} = observed, now) do
    with %InboxWake{wake_id: wake_id} = wake <- get(observed.routine_id),
         true <- wake_id == observed.wake_id do
      insert_kickoff(wake, now)
    else
      _other -> :ok
    end
  end

  defp insert_kickoff(wake, now) do
    opts =
      [
        unique: [
          period: :infinity,
          fields: [:worker, :queue, :args],
          keys: [:routine_id, :wake_id],
          states: [:available, :scheduled, :retryable]
        ]
      ]
      |> maybe_schedule(wake.due_at, with_usec(now))

    wake
    |> job_args()
    |> InboxWakeJob.new(opts)
    |> Oban.insert()
    |> case do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "could not schedule inbox wake #{wake.wake_id} for #{wake.routine_id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp maybe_schedule(opts, due_at, now) do
    if DateTime.after?(due_at, now), do: Keyword.put(opts, :scheduled_at, due_at), else: opts
  end

  defp later_datetime(left, right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _same_or_later -> left
    end
  end

  defp job_args(wake), do: %{routine_id: wake.routine_id, wake_id: wake.wake_id}

  defp correlation(wake), do: "inbox:#{wake.wake_id}:#{wake.claim_token}"

  defp parse_correlation("inbox:" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [wake_id, claim_token] -> {:ok, wake_id, claim_token}
      _other -> :error
    end
  end

  defp parse_correlation(_other), do: :error

  defp agent_state(routine_id) do
    case Agents.status(routine_id) do
      {:ok, status} -> Custode.state_of(status)
      _other -> :offline
    end
  end

  defp blocked_by(:provider_job), do: "provider_job"
  defp blocked_by(:spend_rail), do: "spend_rail"
  defp blocked_by({:gate, blocked_by}), do: blocked_by

  defp blocked_by(state)
       when state in [:running, :waiting_for_user, :awaiting_permission, :paused, :offline],
       do: Atom.to_string(state)

  defp blocked_by(_other), do: nil

  defp fetch_routine(%{id: _id} = routine), do: {:ok, routine}

  defp fetch_routine(routine_id) when is_binary(routine_id) do
    case Routine.get(routine_id) do
      nil -> {:error, :unknown_routine}
      routine -> {:ok, routine}
    end
  end

  defp accepts_wakes(%{on_note: :ignore}), do: {:error, :ignored}
  defp accepts_wakes(_routine), do: :ok

  defp with_usec(%DateTime{microsecond: {value, _precision}} = datetime),
    do: %{datetime | microsecond: {value, 6}}

  defp handler_error(exception) do
    Logger.error(
      "Custode.InboxWakes handler error (kept attached): " <> Exception.message(exception)
    )

    :ok
  end

  defp broadcast(routine_id),
    do: Custode.PubSubBridge.broadcast({:status_changed, routine_id})
end
