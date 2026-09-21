defmodule Custode.Scheduler do
  @moduledoc """
  The routine scheduler that owns routine firing instead of the static Oban
  Cron plugin (#142).

  `Oban.Plugins.Cron` reads its crontab once, at application boot. A routine's
  ARGS were already unfrozen (#7/#121: the crontab schedules `RoutineTick`,
  which resolves the routine's current config at fire time), but the SCHEDULE
  itself stayed boot-baked -- editing a routine's cron expression did nothing
  until the server restarted. A night-watch cadence change (#140) had to wait
  for an activation restart, and #124's cadence advisor would inherit the same
  friction for every accepted suggestion.

  This GenServer dissolves that. It ticks once a minute, evaluates each
  scheduled routine's cron expression against the current time (reusing
  `Oban.Cron.Expression`, the same parser Oban's plugin uses), and inserts the
  same `%{"routine_id" => id}` `Custode.RoutineTick` job the static crontab
  used to. Because it reads the roster through `Custode.Routine.all/0` on every
  tick, a cadence edit -- including one an advisor accepts and writes back via
  design 001's `put_env` -- is live at the NEXT MINUTE with no restart.

  Properties kept from Oban Cron:

    * one insert per routine per matching minute -- a `last_fired` map keyed by
      routine id holds the minute each last fired, so a timer that drifts and
      fires twice inside one wall-clock minute still enqueues at most once
    * `@daily`/`@weekly` and friends keep working (the `Expression` parser
      handles them); `@reboot` becomes a one-time insert at boot, not a
      per-minute match (its `now?/2` is always true, which is why it is
      special-cased out of the minute loop)
    * the scheduler only INSERTS -- the `:ticks` queue withhold (#4, the MCP
      probe) still gates execution, so a reboot tick queued here waits for the
      MCP surface exactly as a crontab-inserted one did

  Sensors and the janitor stay in the static Oban crontab (they change rarely).

  Evaluation is in the configured `:timezone` (#17: the app carries `tzdata`
  and defaults to `America/Los_Angeles`, so `@daily` means local midnight and
  hour-anchored expressions fire on the local hour). The default clock reads
  `Application.get_env(:custode, :timezone, "Etc/UTC")` on EVERY tick, not once
  at boot, so the timezone is live-editable like everything else since #121 --
  and routines stay in lockstep with the sensors, which Oban Cron already
  evaluates in the same configured zone.

  Seams (default to production, injected in tests so no timer or real
  `Oban.insert` is needed):

    * `:clock` -- a 0-arity fun returning the current `DateTime` (in the
      configured timezone by default)
    * `:insert` -- a 1-arity fun given a routine id, enqueues its tick
    * `:interval` -- ms between ticks; `nil` (default) aligns to the next
      minute boundary the way Oban Cron does
    * `:autostart` -- `false` skips arming the timer, so a test drives `tick/1`
  """

  use GenServer

  alias Custode.Routine
  alias Custode.RoutineTick
  alias Oban.Cron.Expression

  # ---- public API ----

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run one evaluation synchronously and return the routine ids fired this tick.
  The scheduled path calls this on its own timer; tests call it directly with
  an injected clock to make minute-boundary behavior deterministic.
  """
  def tick(server \\ __MODULE__), do: GenServer.call(server, :tick)

  @doc """
  The routines in `routines` that match `now` and have not already fired for
  `now`'s minute. Returns `{fired_ids, updated_last_fired}`. Pure: no process,
  no insert. `@reboot` routines are never due here -- they fire once at boot.
  `requested` is `%{routine_id => at}`, the agents' own next-beat requests.
  """
  def due(routines, now, last_fired, requested \\ %{}) do
    minute = truncate_to_minute(now)

    {fired, last_fired} =
      Enum.reduce(routines, {[], last_fired}, fn routine, {fired, seen} ->
        if due?(routine, now, minute, seen, Map.get(requested, routine.id)),
          do: {[routine.id | fired], Map.put(seen, routine.id, minute)},
          else: {fired, seen}
      end)

    {Enum.reverse(fired), last_fired}
  end

  # An agent's own request for its next beat (#526, `Custode.NextBeat`) wins
  # over the cron in both directions: while it is in the future the cron's
  # beats are skipped, and once its time has come the routine is due whether
  # or not the cron matches this minute.
  defp due?(routine, now, minute, seen, requested_at) do
    expr = Expression.parse!(routine.cron)

    cond do
      expr.reboot? -> false
      Map.get(seen, routine.id) == minute -> false
      match?(%DateTime{}, requested_at) -> DateTime.compare(requested_at, now) != :gt
      true -> Expression.now?(expr, now)
    end
  end

  @doc """
  When `cron` next fires after `now`, in UTC, or `nil` when that cannot be
  known: `@reboot`, `"manual"`, no cron at all, an expression that does not
  parse.

  Evaluated in the configured timezone, the same as `due/3`, so `@daily` is
  the operator's midnight and not UTC's.
  """
  @spec next_beat_at(String.t() | nil, DateTime.t()) :: DateTime.t() | nil
  def next_beat_at(cron, now \\ DateTime.utc_now())

  def next_beat_at(cron, %DateTime{} = now) when is_binary(cron) do
    with {:ok, expr} <- Expression.parse(cron),
         %DateTime{} = at <- Expression.next_at(expr, DateTime.shift_zone!(now, timezone())) do
      DateTime.shift_zone!(at, "Etc/UTC")
    else
      _unknown -> nil
    end
  end

  def next_beat_at(_cron, _now), do: nil

  # ---- GenServer ----

  @impl GenServer
  def init(opts) do
    state = %{
      clock: Keyword.get(opts, :clock, &now_in_configured_tz/0),
      insert: Keyword.get(opts, :insert, &insert_tick/1),
      interval: Keyword.get(opts, :interval),
      # agents' own next-beat requests (#526), injectable like the clock
      requested: Keyword.get(opts, :requested, &Custode.NextBeat.pending/0),
      last_fired: %{}
    }

    fire_reboot(state)
    if Keyword.get(opts, :autostart, true), do: schedule_next(state)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:tick, _from, state) do
    {fired, state} = run_once(state)
    {:reply, fired, state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    {_fired, state} = run_once(state)
    schedule_next(state)
    {:noreply, state}
  end

  # ---- internals ----

  defp run_once(state) do
    now = state.clock.()
    requested = state.requested.()
    {fired, last_fired} = due(scheduled_routines(), now, state.last_fired, requested)

    # A request is one-shot, and it is spent the moment it fires: the turn may
    # sit behind the queue for a while, and the next minute must not fire it
    # again.
    for id <- fired, Map.has_key?(requested, id), do: Custode.NextBeat.clear(id)

    Enum.each(fired, state.insert)
    {fired, %{state | last_fired: last_fired}}
  end

  defp scheduled_routines, do: for(r <- Routine.all(), r.cron != :manual, do: r)

  # @reboot routines fire exactly once, at boot -- their now?/2 is always true,
  # so they must NOT go through the minute loop or they would fire every tick.
  defp fire_reboot(state) do
    for r <- scheduled_routines(), Expression.parse!(r.cron).reboot? do
      state.insert.(r.id)
    end
  end

  # Read the timezone per call so a live edit (design 001 put_env) takes effect
  # at the next tick, and so routines evaluate in the same zone as the sensors
  # (still on Oban Cron, which uses this same configured timezone -- #17).
  defp now_in_configured_tz, do: DateTime.now!(timezone())

  defp timezone, do: Application.get_env(:custode, :timezone, "Etc/UTC")

  defp insert_tick(routine_id) do
    {:ok, _job} = Oban.insert(RoutineTick.new(%{"routine_id" => routine_id}, queue: :ticks))
    :ok
  end

  defp truncate_to_minute(now), do: %{now | second: 0, microsecond: {0, 0}}

  # nil interval aligns to the top of the next minute, the way Oban Cron ticks;
  # a fixed interval is for tests that want a fast, predictable timer.
  defp schedule_next(%{interval: nil, clock: clock}),
    do: Process.send_after(self(), :tick, ms_to_next_minute(clock.()))

  defp schedule_next(%{interval: ms}),
    do: Process.send_after(self(), :tick, ms)

  defp ms_to_next_minute(now) do
    {micro, _precision} = now.microsecond
    60_000 - (now.second * 1_000 + div(micro, 1_000))
  end
end
