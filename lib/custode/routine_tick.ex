defmodule Custode.RoutineTick do
  @moduledoc """
  The indirection that keeps scheduled beats honest with live config (#7).

  `Oban.Plugins.Cron` freezes each crontab entry's `args` at application
  boot. When those args were the full agent spec (prompt, model, budget),
  editing a routine did nothing until the server restarted and the agent
  cold-started -- the schedule kept re-inserting the stale spec forever. The
  manual path (`Custode.beat/0`) never had this problem: it rebuilds
  `Routine.tick_args/1` at call time.

  This worker gives the scheduled path the same freshness. `Custode.Scheduler`
  inserts only `%{"routine_id" => id}` (#142 moved routine firing off the
  static Oban crontab); every fire resolves the routine's CURRENT config and
  enqueues the selected provider's Agent Tick with freshly built args. A
  prompt/model/budget edit takes effect on the routine's next beat, no restart
  required -- and with the scheduler reading the roster live, a cadence edit
  now takes effect at the next minute too.

  The bounded GitHub intake pilot uses the same resolved routine as a
  compatibility driver. Intake failure is logged and isolated so the legacy
  Tick is still inserted with exactly the current prompt and execution args.

  `queue: :ticks`, `max_attempts: 1`: a resolution is a point-in-time beat
  like the tick it produces -- a missed one is simply missed, and retrying
  would resolve stale-then. Sharing the `:ticks` queue (withheld until the
  MCP probe answers, #4) means a resolved tick still cannot fire before the
  MCP surface is up. The resolver inserts and returns immediately, so the
  concurrency-1 slot is free for the `Tick` it produced.

  A beat that was never runnable is missed too (#442): one that waited out a
  withheld or paused queue cancels itself rather than firing late. See
  `Custode.Ticks`.

  A beat does not spend a turn the provider has said it will reject (#525).
  When `Custode.Availability.advise/2` says `:defer` with a reset instant, the
  beat snoozes to just past it IF that still lands inside the stale-tick
  window measured from when the beat was due; otherwise it is cancelled as a
  missed beat, because replaying a beat hours late is exactly what
  `Custode.Ticks` exists to prevent and the next cron fire is the retry.
  Either way the feed says why the agent did not run. Only `:defer` with a
  known instant does this: unknown, stale and `:reduce` beat as before, so a
  broken collector cannot stop the fleet. An operator's message never comes
  through here (`Custode.Operator.Actions.message/3` and `Custode.beat/0`
  insert the `Tick` directly), so it is never deferred.
  """

  use Oban.Worker, queue: :ticks, max_attempts: 1

  require Logger

  alias Custode.Availability
  alias Custode.Availability.Advice
  alias Custode.Routine

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"routine_id" => id}} = job) do
    if Custode.Ticks.stale?(job) do
      # queued while the queue was withheld or paused and only reached now
      # (#442): the beat it stood for is long past, and the next one is at
      # most a cron interval away
      {:cancel, {:stale_tick, id}}
    else
      case held(id, job, DateTime.utc_now()) do
        :clear -> beat(id)
        held -> deferred(id, held)
      end
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:invalid_routine_tick, "missing \"routine_id\" in #{inspect(args)}"}}
  end

  # wake a little after the reset rather than on it: clocks differ
  @reset_margin_s 30

  defp held(id, job, now) do
    provider = id |> Routine.get() |> provider_name()

    case Availability.advise(provider, now: now) do
      %Advice{decision: :defer, defer_until: %DateTime{} = until} ->
        wait(job, until, now)

      _advice ->
        :clear
    end
  end

  # the stale-tick window is measured from when the beat was DUE, not from
  # now: a snooze rewrites `scheduled_at`, so this is the only moment the
  # beat's true age is still known
  defp wait(job, until, now) do
    seconds = max(DateTime.diff(until, now, :second), 0) + @reset_margin_s
    wake = DateTime.add(now, seconds, :second)

    # a job with no timestamp is never stale to `Ticks`, so the wait itself
    # is held to the window too
    if seconds > Custode.Ticks.stale_after_s() or Custode.Ticks.stale?(job, wake),
      do: {:missed, until},
      else: {:snooze, seconds, until}
  end

  defp deferred(id, {:snooze, seconds, until}) do
    record_deferred(id, until, "waiting #{seconds}s for it")
    {:snooze, seconds}
  end

  defp deferred(id, {:missed, until}) do
    record_deferred(id, until, "this beat is missed and the next scheduled one will try again")
    {:cancel, {:provider_limited, id, until}}
  end

  defp record_deferred(id, until, outcome) do
    provider = id |> Routine.get() |> provider_name()

    Custode.Feed.record(%{
      event: "beat_deferred",
      agent: id,
      defer_until: DateTime.to_iso8601(until),
      summary:
        "scheduled beat not run: #{provider} is limited until " <>
          "#{Calendar.strftime(until, "%H:%M UTC")}; #{outcome}"
    })
  end

  defp beat(id) do
    case Routine.get(id) do
      nil ->
        # the routine was removed from config since boot; nothing to beat
        {:cancel, {:unknown_routine, id}}

      routine ->
        run_intake(routine)
        tick = Routine.tick_worker(routine)
        {:ok, _job} = Oban.insert(tick.new(Routine.tick_args(routine), queue: :ticks))
        :ok
    end
  end

  defp provider_name(%{provider: provider}), do: Atom.to_string(provider)
  defp provider_name(nil), do: "claude"

  defp run_intake(routine) do
    intake = Application.get_env(:custode, :work_intake, Custode.GitHubIssueIntake)

    case intake.on_routine_tick(routine) do
      :noop ->
        :ok

      :ok ->
        :ok

      {:ok, results} ->
        run_vertical(routine, results)

      {:error, reason} ->
        Logger.warning("work intake failed for #{routine.id}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.warning(
        "work intake crashed for #{routine.id}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning("work intake threw for #{routine.id}: #{inspect({kind, reason})}")
  end

  defp run_vertical(routine, results) do
    vertical = Application.get_env(:custode, :work_vertical, Custode.GitHubIssueVertical)

    case vertical.schedule(routine, results) do
      {:ok, _jobs} ->
        :ok

      {:error, reason} ->
        Logger.warning("work vertical failed for #{routine.id}: #{inspect(reason)}")
    end
  rescue
    exception ->
      Logger.warning(
        "work vertical crashed for #{routine.id}: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )
  catch
    kind, reason ->
      Logger.warning("work vertical threw for #{routine.id}: #{inspect({kind, reason})}")
  end
end
