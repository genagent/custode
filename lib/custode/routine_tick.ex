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
  enqueues a `ObanClaude.Agent.Tick` with freshly built args. A
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
  """

  use Oban.Worker, queue: :ticks, max_attempts: 1

  require Logger

  alias Custode.Routine
  alias ObanClaude.Agent.Tick

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"routine_id" => id}} = job) do
    if Custode.Ticks.stale?(job) do
      # queued while the queue was withheld or paused and only reached now
      # (#442): the beat it stood for is long past, and the next one is at
      # most a cron interval away
      {:cancel, {:stale_tick, id}}
    else
      beat(id)
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:invalid_routine_tick, "missing \"routine_id\" in #{inspect(args)}"}}
  end

  defp beat(id) do
    case Routine.get(id) do
      nil ->
        # the routine was removed from config since boot; nothing to beat
        {:cancel, {:unknown_routine, id}}

      routine ->
        run_intake(routine)
        {:ok, _job} = Oban.insert(Tick.new(Routine.tick_args(routine), queue: :ticks))
        :ok
    end
  end

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
