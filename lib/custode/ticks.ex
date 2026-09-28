defmodule Custode.Ticks do
  @moduledoc """
  Staleness for the `:ticks` queue (#442).

  A routine tick is a point-in-time beat. Its producers (`Custode.Scheduler`
  and `Custode.beat/0`) only INSERT; whether a tick may run is decided by the
  queue, which `Custode.MCP.Probe` withholds when the boot doctor fails and
  `Custode.drain/1` pauses for a restart. Nothing stopped insertion in the
  meantime, so a node that sat with a withheld queue accumulated one job per
  routine per matching minute and ran all of them at the next healthy boot:
  704 after the 2026-09-14 run, each with a prompt and presence line frozen
  days earlier.

  A routine tick that was due longer ago than the window is discarded, not
  replayed. "A missed beat is simply missed" was already the stated doctrine
  for a failed attempt (`max_attempts: 1`); this extends it to the beat that
  never got an attempt. Durable work may share the queue but is excluded by
  worker. In particular, an `InboxWakeJob` represents unseen inbox work and
  must survive an outage.

  The window is `:stale_tick_seconds` (default 600). It is deliberately much
  longer than the wait for the concurrency-1 slot, which is seconds, and much
  shorter than any outage worth the name.
  """

  import Ecto.Query, only: [from: 2]

  @default_stale_after_s 600
  @queue "ticks"

  @doc "The staleness window, in seconds."
  @spec stale_after_s() :: pos_integer()
  def stale_after_s,
    do: Application.get_env(:custode, :stale_tick_seconds, @default_stale_after_s)

  @doc """
  Whether `job` was due longer ago than the window.

  A job with no timestamp is never stale: that is a direct `perform/1` call
  (tests, and the manual beat path), which is by construction happening now.
  """
  @spec stale?(Oban.Job.t(), DateTime.t()) :: boolean()
  def stale?(job, now \\ DateTime.utc_now())

  def stale?(%Oban.Job{} = job, %DateTime{} = now) do
    case due_at(job) do
      nil -> false
      due -> DateTime.diff(now, due, :second) > stale_after_s()
    end
  end

  @doc """
  Cancel every not-yet-run job in `:ticks` that is past the window. Returns
  how many were cancelled.

  Called before the queue starts at boot, which is the one moment a backlog
  of any size can exist without a single job having had the chance to notice
  its own age.
  """
  @spec discard_stale(DateTime.t()) :: non_neg_integer()
  def discard_stale(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -stale_after_s(), :second)

    query =
      from(j in Oban.Job,
        where: j.queue == @queue,
        # Inbox wakes are durable work, not point-in-time beats. Their row
        # remains the source of truth across an outage, and their kickoff job
        # must still be available when the ticks queue returns.
        where: j.worker != "Custode.InboxWakeJob",
        where: j.state in ["available", "scheduled"],
        where: j.scheduled_at < ^cutoff
      )

    {:ok, count} = Oban.cancel_all_jobs(query)
    count
  end

  defp due_at(%Oban.Job{scheduled_at: %DateTime{} = at}), do: at
  defp due_at(%Oban.Job{inserted_at: %DateTime{} = at}), do: at
  defp due_at(%Oban.Job{}), do: nil
end
