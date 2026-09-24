defmodule Custode do
  @moduledoc """
  The human console for the routines. Every function targets the first
  configured routine by default; pass a routine id as the last argument to
  target another.

      iex> Custode.peek()          # status + spend + pendings + recent history
      iex> Custode.note("call the dentist re: tuesday")
      iex> Custode.beat()          # fire a sweep now instead of waiting for cron
      iex> Custode.poke("re-file yesterday's entries under one heading")
      iex> Custode.approve()       # release whatever it is blocked on
      iex> Custode.pause(); Custode.resume()
  """

  alias Custode.Agents
  alias Custode.Gates.Grant
  alias Custode.Routine

  @doc """
  The bare state inside a status, whether it arrives gated
  (`{:awaiting_permission, payload}`) or plain (`:idle`). The one
  definition -- web components and MCP tools all delegate here (#92).
  """
  def state_of({state, _payload}), do: state
  def state_of(state) when is_atom(state), do: state

  @doc "Lifecycle status, straight off the registry."
  def status(id \\ nil), do: Agents.status(fetch!(id).id)

  @doc """
  Drop a note in the routine's inbox. The event kickoff (`on_note: :beat`)
  schedules a debounced beat, so the agent files it shortly -- no waiting
  for cron.
  """
  def note(text, id \\ nil) do
    routine = fetch!(id)
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    Custode.Inbox.drop(routine, "note-#{stamp}.md", text <> "\n")
  end

  @doc "Fire one sweep right now (an out-of-schedule tick through the same policy)."
  def beat(id \\ nil) do
    routine = fetch!(id)
    tick = Routine.tick_worker(routine)

    with {:ok, args, prepared} <- Custode.ConversationArcs.tick_args(routine, :scheduled) do
      case Oban.insert(tick.new(args, queue: :ticks)) do
        {:ok, job} ->
          {:ok, job.id}

        {:error, _reason} = error ->
          Custode.ConversationArcs.abandon(prepared, :enqueue_failed)
          error
      end
    end
  end

  @doc "Fire-and-forget prompt to the agent (queued if it is mid-sweep)."
  def poke(prompt, id \\ nil) do
    routine = fetch!(id)

    with {:ok, delivered, opts} <- Custode.ConversationArcs.operator_delivery(routine, prompt) do
      Agents.cast_prompt(routine.id, delivered, opts)
    end
  end

  @doc "Prompt and block until the turn is enqueued (the answer path for ask_user)."
  def ask(prompt, id \\ nil) do
    routine = fetch!(id)

    with {:ok, delivered, opts} <- Custode.ConversationArcs.operator_delivery(routine, prompt) do
      Agents.submit_prompt(routine.id, delivered, opts)
    end
  end

  @doc "Approve whatever action the agent is blocked on."
  def approve(id \\ nil) do
    agent_id = fetch!(id).id

    case Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id, description: description}}} ->
        IO.puts("approving: #{description}")
        Agents.approve_action(agent_id, action_id)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc """
  Approve an agent's pending action. The one way a surface approves a gate
  (#448): it stamps who decided and from where onto the gate row, then tells
  the engine. `opts`: `:via` (`:liveview` / `:cli` / `:mcp`), `:by` (defaults
  to the operator), `:reason` (an approval may carry one too).
  """
  @spec approve_action(String.t(), String.t(), keyword()) :: term()
  def approve_action(agent_id, action_id, opts \\ []) do
    decide_action(agent_id, action_id, opts, :processing, fn ->
      # The elevation is sized to what was approved (#451): read the class
      # before the decision is recorded, while the gate is still open.
      args =
        agent_id
        |> Custode.Gates.open_class(action_id)
        |> Grant.approval_args(Agents.provider(agent_id))

      # With no override this is the call every engine has. Only an actual
      # override needs approve_action/3 (oban_claude >= 0.5), so a checkout whose
      # engine is behind still approves gates in the default :observe mode.
      if args == %{},
        do: Agents.approve_action(agent_id, action_id),
        else: Agents.approve_action(agent_id, action_id, args: args)
    end)
  end

  @doc """
  Reject an agent's pending action AND teach it (the learning loop on
  "no"): the rejection reason lands in the routine's inbox as a note, so
  the next sweep files it and can remember a standing exception. Without
  this, a reject was silence -- the reason died in the machine log and
  the agent re-proposed variations forever.

  The reason also lands on the gate row (#448), with `opts` as for
  `approve_action/3`, so it outlives the note file.

  What the note teaches depends on what was actually said (#438). A blank
  reason or a surface's old placeholder is NO reason: the note says so and
  forbids a standing exception. `standing: false` marks a stated reason as a
  one-off. Only a stated reason with `standing: true` (the default) keeps the
  REMEMBER instruction.
  """
  def reject_with_note(agent_id, action_id, reason, opts \\ []) do
    detail = proposal_detail(agent_id, action_id)
    stated = stated_reason(reason)
    standing? = stated != nil and Keyword.get(opts, :standing, true)

    result =
      decide_action(
        agent_id,
        action_id,
        Keyword.put(opts, :reason, stated),
        :rejected,
        fn -> Agents.reject_action(agent_id, action_id, stated || "no reason given") end
      )

    if result == :rejected and Custode.Routine.get(agent_id) do
      {:ok, _path} =
        Custode.Inbox.drop(
          agent_id,
          "rejection-#{action_id}.md",
          """
          Your proposal was REJECTED by the operator.

          Proposal: #{detail || action_id}
          Reason: #{stated || "(none given)"}

          #{rejection_lesson(stated, standing?)}
          """
        )
    end

    result
  end

  defp decide_action(agent_id, action_id, opts, success, perform) do
    case Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: ^action_id}}} ->
        carry_out_decision(agent_id, action_id, opts, success, perform)

      {:ok, state} ->
        stale_gate_error(agent_id, action_id, state)
    end
  end

  defp carry_out_decision(agent_id, action_id, opts, success, perform) do
    Custode.Gates.prepare_decision(agent_id, action_id, opts)

    case perform.() do
      ^success -> success
      other -> failed_gate_error(agent_id, action_id, other)
    end
  rescue
    exception ->
      require Logger
      Logger.error(Exception.format(:error, exception, __STACKTRACE__))
      failed_gate_error(agent_id, action_id, :provider_exception)
  catch
    kind, reason ->
      require Logger
      Logger.error(Exception.format(kind, reason, __STACKTRACE__))

      failure = if kind == :exit, do: :provider_exited, else: :provider_failed
      failed_gate_error(agent_id, action_id, failure)
  end

  defp stale_gate_error(agent_id, action_id, state) do
    case safe_recover_gate(agent_id, action_id) do
      {:ok, :requeued} -> {:error, {:stale_gate_requeued, state}}
      {:ok, :orphaned} -> {:error, {:stale_gate_orphaned, state}}
      {:ok, :already_recovered} -> {:error, {:stale_gate_already_recovered, state}}
      {:error, :not_found} -> {:error, {:unknown_action, action_id, state}}
      {:error, reason} -> {:error, {:stale_gate_recovery_failed, state, reason}}
    end
  end

  defp failed_gate_error(agent_id, action_id, failure) do
    case safe_recover_gate(agent_id, action_id) do
      {:ok, recovery} -> {:error, {:decision_failed, recovery, failure}}
      {:error, recovery} -> {:error, {:decision_failed, {:recovery_failed, recovery}, failure}}
    end
  end

  defp safe_recover_gate(agent_id, action_id) do
    Custode.Gates.recover(agent_id, action_id)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  # The strings surfaces used to send when the operator typed nothing. They
  # are not reasons, and an agent told to generalize from one learns a rule
  # nobody stated: `redisctl` permanently stopped readying a green PR on the
  # strength of "rejected from dashboard" (#438).
  @placeholder_reasons [
    "",
    "denied",
    "rejected from dashboard",
    "rejected from the inbox",
    "rejected from CLI"
  ]

  defp stated_reason(reason) do
    trimmed = reason |> to_string() |> String.trim()
    if trimmed in @placeholder_reasons, do: nil, else: trimmed
  end

  # What the agent is told to DO with a rejection. Only a stated reason the
  # operator did not mark one-off may become a standing exception.
  defp rejection_lesson(nil, _standing?) do
    """
    No reason was given, so there is nothing to generalize from. File this
    and move on. Do NOT record a standing exception, and do not stop
    proposing this class of work: you may propose it again when it is
    warranted.
    """
    |> String.trim_trailing()
  end

  defp rejection_lesson(_reason, false) do
    """
    File this. The operator marked it a ONE-OFF: it applies to this proposal
    only. Do NOT record a standing exception; you may propose this class of
    work again when it is warranted.
    """
    |> String.trim_trailing()
  end

  defp rejection_lesson(_reason, true) do
    """
    File this. If the rejection implies a standing exception (a
    class of work not to propose again), REMEMBER it so future
    sweeps do not re-propose variations of the same thing.
    """
    |> String.trim_trailing()
  end

  # What the agent actually proposed, for the rejection note (#436).
  #
  # Read from the pending action the agent process holds, never from the
  # gates table. The gate row is a side effect of a telemetry handler that
  # deliberately swallows its own errors (`Custode.Gates.handle_event/4`, so
  # one transient Repo error cannot detach the pipeline), so it is not a
  # dependable source for the note: under load a busy Repo means no row, the
  # old lookup returned nothing, and the operator's lesson note degraded to
  # an opaque action id -- teaching the agent nothing about what was
  # refused. Taking the FIRST open gate could also describe a different
  # proposal entirely when two were pending.
  #
  # Must be read BEFORE the rejection clears `pending_action`. A rejection
  # only succeeds when the agent holds this exact action, so the fallback is
  # unreachable on the success path and the note is complete whenever it is
  # written at all.
  defp proposal_detail(agent_id, action_id) do
    case Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: ^action_id, description: description}}}
      when is_binary(description) ->
        description

      _other ->
        nil
    end
  end

  @doc "Reject whatever action the agent is blocked on (console shorthand)."
  def reject(reason \\ "denied", id \\ nil) do
    agent_id = fetch!(id).id

    case Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id}}} ->
        Agents.reject_action(agent_id, action_id, reason)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc "Emergency lockdown: no sweeps, no prompts, until resume/1."
  def pause(id \\ nil), do: Agents.emergency_pause(fetch!(id).id)

  @doc "Release a paused agent."
  def resume(id \\ nil), do: Agents.resume_agent(fetch!(id).id)

  @doc """
  The emergency brake (#14): pause every agent not already paused/offline.

  Operation-routed clients may supply the pause function; the zero-argument
  facade retains its original direct behavior for compatibility.
  """
  def pause_all(pause_fun \\ &Agents.emergency_pause/1) when is_function(pause_fun, 1) do
    ids =
      for {id, status} <- Agents.list(), pausable?(status) do
        pause_fun.(id)
        id
      end

    Custode.Feed.record(%{
      event: "paused",
      agent: "custode",
      action: "fleet pause-all: #{length(ids)} agent(s) paused (#{Enum.join(ids, ", ")})"
    })

    {:ok, ids}
  end

  @doc "Release the brake: resume every paused agent."
  def resume_all do
    ids =
      for {id, status} <- Agents.list(), paused?(status) do
        Agents.resume_agent(id)
        id
      end

    {:ok, ids}
  end

  defp pausable?({state, _payload}), do: state not in [:paused]
  defp pausable?(state), do: state not in [:paused, :offline]

  defp paused?(:paused), do: true
  defp paused?(_status), do: false

  @doc """
  Begin a graceful drain without blocking the caller, and say how many turns
  it is waiting on.

  The queues are paused HERE, synchronously, because closing the race is the
  half that must not wait on a task being scheduled. The blocking wait and the
  stop are handed to a task; `drain/1` re-pausing paused queues is a no-op.

  One entry point for every surface that can drain (the MCP tool, the console)
  so they cannot drift. `:drain_fun` is the seam tests use: a real
  `System.stop/0` would take down the test VM. Queue admission must be
  confirmed before either the active-work read or the background task starts.
  A pause failure returns an error and leaves already-paused queues closed.
  The second argument accepts the same test seams as `drain/1`.
  """
  @spec start_drain(non_neg_integer() | nil, keyword()) ::
          non_neg_integer() | {:error, String.t()}
  def start_drain(timeout_ms \\ nil, opts \\ []) do
    with {:ok, queues} <- Custode.Drain.pause(opts) do
      executing = Keyword.get(opts, :executing, &executing_turns/0)
      count = length(executing.())
      opts = Keyword.put(opts, :queues, queues)
      opts = if timeout_ms, do: Keyword.put(opts, :timeout, timeout_ms), else: opts
      drain_fun = Application.get_env(:custode, :drain_fun, &drain/1)

      wait = fn -> drain_fun.(opts) end

      case Task.Supervisor.start_child(Custode.TaskSupervisor, wait) do
        {:ok, _pid} -> count
        {:error, reason} -> {:error, "could not start drain wait: #{inspect(reason)}"}
      end
    end
  end

  @doc """
  Graceful drain for a restart (#132): pause every executing queue, wait out
  the turns already running, then stop the VM.

  Pausing FIRST is the whole point. The external restart runbook was
  check-then-kill -- it observed zero executing jobs, then sent `SIGTERM` --
  and a cron boundary firing between the observation and the signal could
  start a fresh turn that Oban's 15s shutdown grace then killed mid-flight,
  orphaning the claude subprocess and leaving Lifeline to re-run the row 20
  minutes later (double claude, double spend). Paused queues cannot start new
  work, so the wait converges and the stop is safe. The #77/#128 instance
  heartbeat guards the other half (a successor cannot boot behind us) and
  `Custode.Instance.terminate/2` releases the row on this graceful path, so
  `drain` + start is a complete restart with no operator polling.

  Returns `:ok` once the VM is stopping. With a finite `:timeout` it gives up
  rather than waiting forever, returning `{:error, {:timeout, jobs}}` with the
  still-executing jobs (so the operator can choose between waiting longer and
  `CUSTODE_TAKEOVER`) and it does NOT stop. On that timeout the queues STAY
  PAUSED -- deliberately, since resuming would reopen the race the drain
  exists to close; `Oban.resume_queue/1` per queue is the explicit abort
  path. One more operational note (2026-07-22 wedge): teardown can hang in
  the transport drain AFTER every turn finishes -- if the VM lingers past
  `System.stop`, the runbook is force-kill and let the instance heartbeat
  (#77) go stale before the successor boots.

  Options (the seams default to production and are injected in tests, where a
  real `System.stop/0` would take down the test VM):

    * `:timeout` -- ms to wait for executing to reach zero (default `:infinity`)
    * `:poll` -- ms between checks (default 250)
    * `:pause_timeout` -- ms to await queue pause confirmation (default 5,000)
    * `:queues` / `:pause` / `:check_queue` / `:executing` / `:stop` -- injectable seams
  """
  def drain(opts \\ []) do
    executing = Keyword.get(opts, :executing, &executing_jobs/0)
    stop = Keyword.get(opts, :stop, &System.stop/0)
    poll = Keyword.get(opts, :poll, 250)
    deadline = drain_deadline(Keyword.get(opts, :timeout, :infinity))

    with {:ok, queues} <- Custode.Drain.pause(opts) do
      Custode.Feed.record(%{
        event: "paused",
        agent: "custode",
        action: "drain: paused #{Enum.join(queues, ", ")}; waiting out executing turns"
      })

      case await_drained(executing, poll, deadline) do
        :ok ->
          stop.()
          :ok

        {:timeout, jobs} ->
          Custode.Feed.record(%{
            event: "turn_failed",
            agent: "custode",
            kind: "drain_timeout",
            detail: "#{length(jobs)} turn(s) still executing at the drain deadline; not stopping"
          })

          {:error, {:timeout, jobs}}
      end
    end
  end

  @doc "The still-executing turns Oban has not yet finished; [] means safe to stop."
  def executing_turns do
    executing_jobs()
  end

  # the still-executing turns Oban has not yet finished; [] means safe to stop
  defp executing_jobs do
    import Ecto.Query, only: [from: 2]

    Custode.Repo.all(
      from(j in Oban.Job,
        where: j.state == "executing",
        select: %{id: j.id, queue: j.queue, worker: j.worker}
      )
    )
  end

  defp await_drained(executing, poll, deadline) do
    case executing.() do
      [] ->
        :ok

      jobs ->
        if drain_past?(deadline) do
          {:timeout, jobs}
        else
          Process.sleep(poll)
          await_drained(executing, poll, deadline)
        end
    end
  end

  defp drain_deadline(:infinity), do: :infinity
  defp drain_deadline(ms) when is_integer(ms), do: System.monotonic_time(:millisecond) + ms

  defp drain_past?(:infinity), do: false
  defp drain_past?(deadline), do: System.monotonic_time(:millisecond) >= deadline

  @doc "Print the routine's open todos (ids for `done/1`)."
  def todos(id \\ nil) do
    for todo <- Custode.Notebook.todos(fetch!(id).id) do
      IO.puts("  ##{todo.id}  #{todo.text}")
    end

    :ok
  end

  @doc "Mark a todo done by id."
  def done(todo_id), do: Custode.Notebook.todo_complete(todo_id)

  @doc "Print the routine's newest `n` journal entries."
  def journal(n \\ 10, id \\ nil) do
    for entry <- Custode.Notebook.journal(fetch!(id).id, n) do
      stamp = Calendar.strftime(entry.inserted_at, "%m-%d %H:%M")
      IO.puts("  #{stamp}  #{entry.title || String.slice(entry.body, 0, 70)}")
    end

    :ok
  end

  @doc "Print today's (UTC) spend per routine and the fleet total."
  def spend do
    for routine <- Routine.all() do
      budget = if routine.daily_budget_usd, do: " / $#{routine.daily_budget_usd}", else: ""

      IO.puts(
        "  #{routine.id}: $#{Float.round(Custode.SpendLedger.today(routine.id), 4)}#{budget}"
      )
    end

    IO.puts("  fleet today: $#{Float.round(Custode.SpendLedger.fleet_today(), 4)}")
    :ok
  end

  @doc "Pretty-print the last `n` feed entries (see `Custode.Feed`)."
  def feed(n \\ 20) do
    case Custode.Feed.tail(n) do
      [] -> IO.puts("(no feed yet: #{Custode.Feed.path()})")
      entries -> Enum.each(entries, &print_feed_entry/1)
    end

    :ok
  end

  defp print_feed_entry(entry) do
    time = String.slice(entry["at"], 11, 8)
    detail = entry["summary"] || entry["action"] || entry["question"] || entry["kind"] || ""
    cost = if entry["cost_usd"], do: " ($#{entry["cost_usd"]})", else: ""
    IO.puts("#{time} [#{entry["agent"]}] #{entry["event"]}#{cost} #{detail}")
  end

  @doc "One readable snapshot: status, spend, pendings, and recent history."
  def peek(id \\ nil) do
    routine = fetch!(id)

    case Agents.status(routine.id) do
      {:ok, :offline} ->
        IO.puts("#{routine.id}: offline (next cron beat will start it; or Custode.beat())")

      {:ok, status} ->
        {:ok, info} = Agents.info(routine.id)
        {:ok, history} = Agents.history(routine.id)

        IO.puts("""
        #{routine.id}: #{inspect(status)}
          turns=#{info.turns} spend=$#{Float.round(info.cost_usd, 4)} session=#{info.session_id || "-"}
        """)

        for entry <- Enum.take(history, -8) do
          IO.puts("  " <> inspect(entry, printable_limit: 120))
        end
    end

    :ok
  end

  defp fetch!(nil), do: Routine.default()

  defp fetch!(id) do
    Routine.get(id) || raise ArgumentError, "no routine #{inspect(id)} configured"
  end
end
