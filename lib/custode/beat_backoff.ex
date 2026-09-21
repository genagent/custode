defmodule Custode.BeatBackoff do
  @moduledoc """
  A retryable failed beat pushes the next one out (#543).

  A routine whose turn fails keeps its cadence, so a `*/15` agent behind a
  rate limit fails four times an hour. After a failure whose
  `Custode.TurnFailure` category is retryable, the next SCHEDULED beat waits:
  the routine's own cron interval, doubled per consecutive failure, capped at
  the `:next_beat_bounds` maximum.

  Count consecutive classified failures across categories (#560): a timeout
  followed by a rate limit is two failed turns, so a `*/15` routine waits
  15 minutes, then 30. A different cause is not evidence of recovery. Earlier
  non-retryable failures count too; the LATEST category decides whether to
  back off, and only a successful turn ends the count. Attention separately
  counts the latest category's run because its headline names one remedy.

  There is no second mechanism. The wait is a `Custode.NextBeat` request, so
  it is one-shot and anything that starts a turn (an operator message, a
  sensor wake, `beat now`) clears it. There is no reset code either: the
  count is `Custode.TurnFailure.streak/1`, read from the feed, and a `turn`
  entry ends the run.

  A non-retryable category does not back off. It raises `:turn_failing` and
  waits for the operator, and running less often would only delay the proof
  that the operator's fix worked.

  `config :custode, :beat_backoff, false` switches the whole thing off.
  """

  alias Custode.NextBeat
  alias Custode.Routine
  alias Custode.Scheduler
  alias Custode.TurnFailure

  # `@daily`-and-slower crons already exceed any useful backoff, and a manual
  # or unparseable cron has no interval at all.
  @default_interval_minutes 60
  # 2^20 intervals is past any bound; the cap keeps the integer small.
  @max_doublings 20

  @doc "Whether failed beats back off at all."
  @spec enabled?() :: boolean()
  def enabled?, do: Application.get_env(:custode, :beat_backoff, true)

  @doc """
  Called once a `turn_failed` entry for `agent_id` is in the feed. Returns the
  backoff it set, or `:noop` with nothing written.
  """
  @spec after_failure(String.t(), TurnFailure.category(), keyword()) ::
          {:ok, %{minutes: pos_integer(), failures: pos_integer()}} | :noop
  def after_failure(agent_id, category, opts \\ []) do
    routine = enabled?() and TurnFailure.retryable?(category) and Routine.get(agent_id)

    if routine, do: back_off(routine, category, opts), else: :noop
  end

  defp back_off(routine, category, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    failures = routine.id |> TurnFailure.streak() |> length() |> max(1)
    minutes = wait_minutes(routine.cron, failures, now)

    if later_request?(routine.id, minutes, now) do
      # The agent asked, during the failed turn, to wait LONGER than this. It
      # knows something the doubling does not.
      :noop
    else
      reason = "backoff: #{failures} consecutive failed turn(s), #{category}"
      {:ok, %{minutes: granted}} = NextBeat.request(routine.id, minutes, now: now, reason: reason)

      Custode.Feed.record(%{
        event: "beat_backoff",
        agent: routine.id,
        minutes: granted,
        failures: failures,
        category: category,
        summary:
          "next scheduled beat in #{granted}m after #{failures} failed turn(s): #{category}"
      })

      {:ok, %{minutes: granted, failures: failures}}
    end
  end

  @doc """
  The wait after `failures` consecutive failed turns: the cron's own interval
  for the first, doubling from there, never past the `:next_beat_bounds` max.
  """
  @spec wait_minutes(String.t() | atom() | nil, pos_integer(), DateTime.t()) :: pos_integer()
  def wait_minutes(cron, failures, now \\ DateTime.utc_now()) do
    {_low, high} = NextBeat.bounds()
    doublings = min(failures - 1, @max_doublings)
    min(interval_minutes(cron, now) * Integer.pow(2, doublings), high)
  end

  @doc "Minutes between the cron's next two fires, or a default when it has none."
  @spec interval_minutes(String.t() | atom() | nil, DateTime.t()) :: pos_integer()
  def interval_minutes(cron, now \\ DateTime.utc_now()) do
    with %DateTime{} = first <- Scheduler.next_beat_at(cron, now),
         %DateTime{} = second <- Scheduler.next_beat_at(cron, first) do
      max(div(DateTime.diff(second, first, :second), 60), 1)
    else
      _no_interval -> @default_interval_minutes
    end
  end

  defp later_request?(routine_id, minutes, now) do
    case NextBeat.get(routine_id) do
      %NextBeat{at: at} -> DateTime.compare(at, DateTime.add(now, minutes * 60, :second)) == :gt
      nil -> false
    end
  end
end
