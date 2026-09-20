defmodule Custode.Aging.Job do
  @moduledoc """
  The clock for `Custode.Aging` (#446): one run per `:aging_cron` line.

  It hands `Custode.Aging.run/2` its own `scheduled_at` and not the wall
  clock. Oban's cron inserts on the minute, so consecutive `scheduled_at`
  values are exactly one interval apart however late a run actually starts,
  and the `(now - interval, now]` windows tile with no gap and no overlap.

  `max_attempts: 1`, like the sensors it shares a queue with: a retry would
  re-send notifications the first attempt already sent.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  @impl Oban.Worker
  def perform(%Oban.Job{scheduled_at: scheduled_at}) do
    now = scheduled_at || DateTime.utc_now()
    Custode.Aging.run(now, Custode.Aging.interval_s())
    :ok
  end
end
