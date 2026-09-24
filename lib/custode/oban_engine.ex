defmodule Custode.ObanEngine do
  @moduledoc """
  SQLite Oban engine with bounded retries for job acknowledgements.

  A worker has already performed its external work when Oban records the
  outcome. SQLite may return `SQLITE_BUSY` immediately to avoid a lock-upgrade
  deadlock, even with a connection busy timeout. Retrying here repeats only
  the idempotent state transition. It never invokes the worker again.
  """

  @behaviour Oban.Engine

  require Logger

  alias Oban.Engines.Lite

  @default_retry_delays [50, 100, 200, 400]

  @impl true
  defdelegate init(conf, opts), to: Lite

  @impl true
  defdelegate put_meta(conf, meta, key, value), to: Lite

  @impl true
  defdelegate check_meta(conf, meta, running), to: Lite

  @impl true
  defdelegate refresh(conf, meta), to: Lite

  @impl true
  defdelegate shutdown(conf, meta), to: Lite

  @impl true
  defdelegate insert_job(conf, changeset, opts), to: Lite

  @impl true
  defdelegate insert_all_jobs(conf, changesets, opts), to: Lite

  @impl true
  defdelegate stage_jobs(conf, queryable, opts), to: Lite

  @impl true
  defdelegate fetch_jobs(conf, meta, running), to: Lite

  @impl true
  defdelegate prune_jobs(conf, queryable, opts), to: Lite

  @impl true
  def complete_job(conf, job),
    do: acknowledge(:complete_job, job, fn -> Lite.complete_job(conf, job) end)

  @impl true
  def discard_job(conf, job),
    do: acknowledge(:discard_job, job, fn -> Lite.discard_job(conf, job) end)

  @impl true
  def error_job(conf, job, seconds),
    do: acknowledge(:error_job, job, fn -> Lite.error_job(conf, job, seconds) end)

  @impl true
  def snooze_job(conf, job, seconds),
    do: acknowledge(:snooze_job, job, fn -> Lite.snooze_job(conf, job, seconds) end)

  @impl true
  def cancel_job(conf, job),
    do: acknowledge(:cancel_job, job, fn -> Lite.cancel_job(conf, job) end)

  @impl true
  defdelegate cancel_all_jobs(conf, queryable), to: Lite

  @impl true
  defdelegate delete_job(conf, job), to: Lite

  @impl true
  defdelegate delete_all_jobs(conf, queryable), to: Lite

  @impl true
  defdelegate retry_job(conf, job), to: Lite

  @impl true
  defdelegate retry_all_jobs(conf, queryable), to: Lite

  @impl true
  defdelegate update_job(conf, job, changes), to: Lite

  @doc false
  def retry_busy(fun, opts \\ []) when is_function(fun, 0) do
    delays = Keyword.get(opts, :delays, retry_delays())
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    metadata = Keyword.get(opts, :metadata, %{})

    do_retry_busy(fun, delays, sleep, metadata, 1)
  end

  defp acknowledge(operation, job, fun) do
    retry_busy(fun, metadata: %{operation: operation, job_id: job.id})
  end

  defp do_retry_busy(fun, delays, sleep, metadata, attempt) do
    fun.()
  rescue
    error in Exqlite.Error ->
      if busy?(error) do
        retry_or_raise(error, __STACKTRACE__, fun, delays, sleep, metadata, attempt)
      else
        reraise error, __STACKTRACE__
      end
  end

  defp retry_or_raise(error, stacktrace, _fun, [], _sleep, metadata, attempt) do
    Logger.error(
      "Oban acknowledgement stayed busy after #{attempt} attempts",
      Map.to_list(metadata)
    )

    reraise error, stacktrace
  end

  defp retry_or_raise(error, _stacktrace, fun, [delay | rest], sleep, metadata, attempt) do
    :telemetry.execute(
      [:custode, :oban, :ack_retry],
      %{delay_ms: delay, attempt: attempt},
      Map.put(metadata, :error, error)
    )

    sleep.(delay)
    do_retry_busy(fun, rest, sleep, metadata, attempt + 1)
  end

  defp retry_delays do
    Application.get_env(:custode, :oban_ack_retry_delays, @default_retry_delays)
  end

  defp busy?(%Exqlite.Error{message: message}) do
    normalized = String.downcase(message)

    String.contains?(normalized, ["database busy", "database is busy", "database is locked"])
  end
end
