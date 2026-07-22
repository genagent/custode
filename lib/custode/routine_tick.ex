defmodule Custode.RoutineTick do
  @moduledoc """
  The indirection that keeps scheduled beats honest with live config (#7).

  `Oban.Plugins.Cron` freezes each crontab entry's `args` at application
  boot. When those args were the full agent spec (prompt, model, budget),
  editing a routine did nothing until the server restarted and the agent
  cold-started -- the schedule kept re-inserting the stale spec forever. The
  manual path (`Custode.beat/0`) never had this problem: it rebuilds
  `Routine.tick_args/1` at call time.

  This worker gives the cron path the same freshness. The crontab entry
  carries only `%{"routine_id" => id}`; every fire resolves the routine's
  CURRENT config and enqueues a `ObanClaude.Agent.Tick` with freshly built
  args. A prompt/model/budget edit takes effect on the routine's next beat,
  no restart required.

  `queue: :ticks`, `max_attempts: 1`: a resolution is a point-in-time beat
  like the tick it produces -- a missed one is simply missed, and retrying
  would resolve stale-then. Sharing the `:ticks` queue (withheld until the
  MCP probe answers, #4) means a resolved tick still cannot fire before the
  MCP surface is up. The resolver inserts and returns immediately, so the
  concurrency-1 slot is free for the `Tick` it produced.
  """

  use Oban.Worker, queue: :ticks, max_attempts: 1

  alias Custode.Routine
  alias ObanClaude.Agent.Tick

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"routine_id" => id}}) do
    case Routine.get(id) do
      nil ->
        # the routine was removed from config since boot; nothing to beat
        {:cancel, {:unknown_routine, id}}

      routine ->
        {:ok, _job} = Oban.insert(Tick.new(Routine.tick_args(routine), queue: :ticks))
        :ok
    end
  end

  def perform(%Oban.Job{args: args}) do
    {:cancel, {:invalid_routine_tick, "missing \"routine_id\" in #{inspect(args)}"}}
  end
end
