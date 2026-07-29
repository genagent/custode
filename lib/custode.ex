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

  alias Custode.Routine
  alias ObanClaude.Agent
  alias ObanClaude.Agent.Tick

  @doc """
  The bare state inside a status, whether it arrives gated
  (`{:awaiting_permission, payload}`) or plain (`:idle`). The one
  definition -- web components and MCP tools all delegate here (#92).
  """
  def state_of({state, _payload}), do: state
  def state_of(state) when is_atom(state), do: state

  @doc "Lifecycle status, straight off the registry."
  def status(id \\ nil), do: Agent.status(fetch!(id).id)

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

    {:ok, job} = Oban.insert(Tick.new(Routine.tick_args(routine), queue: :ticks))
    {:ok, job.id}
  end

  @doc "Fire-and-forget prompt to the agent (queued if it is mid-sweep)."
  def poke(prompt, id \\ nil), do: Agent.cast_prompt(fetch!(id).id, prompt)

  @doc "Prompt and block until the turn is enqueued (the answer path for ask_user)."
  def ask(prompt, id \\ nil), do: Agent.submit_prompt(fetch!(id).id, prompt)

  @doc "Approve whatever action the agent is blocked on."
  def approve(id \\ nil) do
    agent_id = fetch!(id).id

    case Agent.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id, description: description}}} ->
        IO.puts("approving: #{description}")
        Agent.approve_action(agent_id, action_id)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc """
  Reject an agent's pending action AND teach it (the learning loop on
  "no"): the rejection reason lands in the routine's inbox as a note, so
  the next sweep files it and can remember a standing exception. Without
  this, a reject was silence -- the reason died in the machine log and
  the agent re-proposed variations forever.
  """
  def reject_with_note(agent_id, action_id, reason) do
    detail =
      case Custode.Gates.open_gates(agent_id) do
        [gate | _rest] -> gate.detail
        [] -> nil
      end

    result = Agent.reject_action(agent_id, action_id, reason)

    if result == :rejected and Custode.Routine.get(agent_id) do
      {:ok, _path} =
        Custode.Inbox.drop(
          agent_id,
          "rejection-#{action_id}.md",
          """
          Your proposal was REJECTED by the operator.

          Proposal: #{detail || action_id}
          Reason: #{reason}

          File this. If the rejection implies a standing exception (a
          class of work not to propose again), REMEMBER it so future
          sweeps do not re-propose variations of the same thing.
          """
        )
    end

    result
  end

  @doc "Reject whatever action the agent is blocked on (console shorthand)."
  def reject(reason \\ "denied", id \\ nil) do
    agent_id = fetch!(id).id

    case Agent.status(agent_id) do
      {:ok, {:awaiting_permission, %{id: action_id}}} ->
        Agent.reject_action(agent_id, action_id, reason)

      {:ok, other} ->
        {:error, {:nothing_pending, other}}
    end
  end

  @doc "Emergency lockdown: no sweeps, no prompts, until resume/1."
  def pause(id \\ nil), do: Agent.emergency_pause(fetch!(id).id)

  @doc "Release a paused agent."
  def resume(id \\ nil), do: Agent.resume_agent(fetch!(id).id)

  @doc """
  The emergency brake (#14): pause every agent not already paused/offline.

  Operation-routed clients may supply the pause function; the zero-argument
  facade retains its original direct behavior for compatibility.
  """
  def pause_all(pause_fun \\ &Agent.emergency_pause/1) when is_function(pause_fun, 1) do
    ids =
      for {id, status} <- Agent.list(), pausable?(status) do
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
      for {id, status} <- Agent.list(), paused?(status) do
        Agent.resume_agent(id)
        id
      end

    {:ok, ids}
  end

  defp pausable?({state, _payload}), do: state not in [:paused]
  defp pausable?(state), do: state not in [:paused, :offline]

  defp paused?(:paused), do: true
  defp paused?(_status), do: false

  @drain_queues [:ticks, :agents, :sensors]

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
    * `:queues` / `:pause` / `:executing` / `:stop` -- injectable seams
  """
  def drain(opts \\ []) do
    queues = Keyword.get(opts, :queues, @drain_queues)
    pause = Keyword.get(opts, :pause, &Oban.pause_queue(queue: &1))
    executing = Keyword.get(opts, :executing, &executing_jobs/0)
    stop = Keyword.get(opts, :stop, &System.stop/0)
    poll = Keyword.get(opts, :poll, 250)
    deadline = drain_deadline(Keyword.get(opts, :timeout, :infinity))

    Enum.each(queues, pause)

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

    case Agent.status(routine.id) do
      {:ok, :offline} ->
        IO.puts("#{routine.id}: offline (next cron beat will start it; or Custode.beat())")

      {:ok, status} ->
        {:ok, info} = Agent.info(routine.id)
        {:ok, history} = Agent.history(routine.id)

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
