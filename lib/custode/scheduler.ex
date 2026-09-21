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

    * one insert per routine per matching minute -- a `last_fired` map handles
      timer drift in one scheduler process, while the Oban job carries a
      durable routine/minute identity that survives scheduler restart
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
    * `:insert_job` -- a 1-arity fun given an Oban changeset, enqueues its tick
    * `:interval` -- ms between ticks; `nil` (default) aligns to the next
      minute boundary the way Oban Cron does
    * `:autostart` -- `false` skips arming the timer, so a test drives `tick/1`
  """

  use GenServer

  require Logger

  alias Custode.NextBeat
  alias Custode.Repo
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
  `requested` is `%{routine_id => at_or_request}`, the agents' own next-beat
  requests. Production passes full `NextBeat` rows so the handoff can consume
  the exact request it observed; callers that only evaluate due work may pass
  `DateTime` values.
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
    requested_at = if match?(%NextBeat{}, requested_at), do: requested_at.at, else: requested_at

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
    insert_job = Keyword.get(opts, :insert_job, &Oban.insert/1)
    handoff = fn occurrence -> handoff(occurrence, insert_job) end

    state = %{
      clock: Keyword.get(opts, :clock, &now_in_configured_tz/0),
      handoff: handoff,
      interval: Keyword.get(opts, :interval),
      # agents' own next-beat requests (#526), injectable like the clock
      requested: Keyword.get(opts, :requested, &NextBeat.pending_requests/0),
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
    minute = truncate_to_minute(now)
    {due_ids, _seen} = due(scheduled_routines(), now, state.last_fired, requested)

    {fired, handed_off} =
      Enum.reduce(due_ids, {[], []}, fn id, {fired, handed_off} ->
        occurrence = occurrence(id, minute, Map.get(requested, id))

        case safe_handoff(state.handoff, occurrence) do
          :inserted ->
            {[id | fired], [id | handed_off]}

          :duplicate ->
            {fired, [id | handed_off]}

          {:error, reason} ->
            Logger.warning("scheduler handoff failed for #{id}: #{inspect(reason)}")
            {fired, handed_off}
        end
      end)

    last_fired = Enum.reduce(handed_off, state.last_fired, &Map.put(&2, &1, minute))
    {Enum.reverse(fired), %{state | last_fired: last_fired}}
  end

  defp scheduled_routines, do: for(r <- Routine.all(), r.cron != :manual, do: r)

  # @reboot routines fire exactly once, at boot -- their now?/2 is always true,
  # so they must NOT go through the minute loop or they would fire every tick.
  defp fire_reboot(state) do
    for r <- scheduled_routines(), Expression.parse!(r.cron).reboot? do
      case safe_handoff(state.handoff, %{routine_id: r.id, source: :reboot}) do
        status when status in [:inserted, :duplicate] ->
          :ok

        {:error, reason} ->
          Logger.warning("@reboot handoff failed for #{r.id}: #{inspect(reason)}")
      end
    end
  end

  # Read the timezone per call so a live edit (design 001 put_env) takes effect
  # at the next tick, and so routines evaluate in the same zone as the sensors
  # (still on Oban Cron, which uses this same configured timezone -- #17).
  defp now_in_configured_tz, do: DateTime.now!(timezone())

  defp timezone, do: Application.get_env(:custode, :timezone, "Etc/UTC")

  defp occurrence(routine_id, minute, %NextBeat{} = request) do
    %{routine_id: routine_id, source: :requested, request: request, minute: minute}
  end

  defp occurrence(routine_id, minute, _request) do
    %{routine_id: routine_id, source: :cron, minute: minute}
  end

  defp handoff(%{source: :requested, request: request} = occurrence, insert_job) do
    Repo.transaction(
      fn -> consume_request(request, occurrence, insert_job) end,
      mode: :immediate
    )
    |> case do
      {:ok, status} when status in [:inserted, :duplicate] -> status
      {:error, reason} -> {:error, reason}
    end
  end

  defp handoff(occurrence, insert_job), do: insert_occurrence(occurrence, insert_job)

  defp consume_request(request, occurrence, insert_job) do
    case NextBeat.get(request.routine_id) do
      %NextBeat{} = current
      when current.at == request.at and current.inserted_at == request.inserted_at ->
        consume_current_request(request, occurrence, insert_job)

      _changed ->
        Repo.rollback(:request_changed)
    end
  end

  defp consume_current_request(request, occurrence, insert_job) do
    with status when status in [:inserted, :duplicate] <-
           insert_occurrence(occurrence, insert_job),
         1 <- NextBeat.clear_observed(request) do
      status
    else
      {:error, reason} -> Repo.rollback({:enqueue_failed, reason})
      count -> Repo.rollback({:request_changed, count})
    end
  end

  defp insert_occurrence(occurrence, insert_job) do
    case insert_job.(tick_changeset(occurrence)) do
      {:ok, %Oban.Job{conflict?: true}} -> :duplicate
      {:ok, _job} -> :inserted
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_insert_result, other}}
    end
  end

  defp safe_handoff(handoff, occurrence) do
    handoff.(occurrence)
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp tick_changeset(%{routine_id: id, source: :reboot}) do
    RoutineTick.new(%{"routine_id" => id, "schedule_source" => "reboot"}, queue: :ticks)
  end

  defp tick_changeset(%{routine_id: id} = occurrence) do
    RoutineTick.new(
      %{"routine_id" => id, "schedule_occurrence" => occurrence_key(occurrence)},
      queue: :ticks,
      unique: [
        period: :infinity,
        fields: [:worker, :args],
        keys: [:schedule_occurrence],
        states: :all
      ]
    )
  end

  defp occurrence_key(%{source: :cron, routine_id: id, minute: minute}) do
    minute = minute |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
    "cron:#{id}:#{minute}"
  end

  defp occurrence_key(%{source: :requested, request: request}) do
    inserted_at = DateTime.to_iso8601(request.inserted_at)
    requested_at = DateTime.to_iso8601(request.at)
    "requested:#{request.routine_id}:#{inserted_at}:#{requested_at}"
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
