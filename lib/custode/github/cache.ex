defmodule Custode.GitHub.Cache do
  @moduledoc """
  TTL cache over `Custode.GitHub` fetches, tuned for LiveView reads:

    * a fresh hit answers from ETS;
    * a stale hit answers from ETS AND kicks an async refresh (stale beats
      blank -- the panel updates when the fetch lands);
    * a cold miss answers `:loading` and kicks the refresh;
    * a repo whose fetch failed and that has nothing cached answers
      `{:error, reason}`.

  Refreshes are deduplicated (one in flight per repo), run in a `Task` so a
  GitHub hiccup never takes the cache down, and broadcast
  `{:repo_overview, repo}` on the agents topic when what a page would draw
  changed.

  ## A failure is cached too (#485)

  A failed fetch used to leave no trace, so the next read found nothing and
  fetched again. Every PubSub event refreshes the fleet page and the console,
  so one repository GitHub refuses (`redis/redisctl`, behind an org's SAML
  SSO) was refetched several times a minute for as long as a page was open,
  and each attempt logged the whole inspected `%GhEx.Error{}`, response
  headers included.

  Now a failure writes a row carrying a short reason, the consecutive failure
  count, and the time before which no read refetches: `:github_retry_first_ms`
  (60 seconds) after the first failure, `:github_retry_repeat_ms` (300
  seconds) after every consecutive one. A success deletes the row.

  The log follows the TRANSITION, never the attempt: one warning when a repo
  goes from ok or unknown to failing, one info when it recovers, nothing on a
  repeat failure.

  Stale still beats blank. A repo with an overview cached keeps answering
  `{:ok, overview}` while its refresh fails, so a GitHub hiccup does not blank
  a panel, or drop a red-main signal for a minute and then raise it again.
  There the failure row only stops the refetching. `{:error, reason}` is for
  the repo with nothing to show, which used to be `:loading` forever.
  """

  use GenServer

  require Logger

  @table :custode_github_cache
  @default_ttl_ms 120_000
  @default_retry_first_ms 60_000
  @default_retry_repeat_ms 300_000

  @reason_limit 120

  @type reading :: {:ok, map()} | {:error, String.t()} | :loading

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  See `Custode.GitHub.overview/2`.

  `:now` is the read's clock in monotonic milliseconds. It defaults to the
  real one; a test passes a later value to read past a backoff window without
  sleeping through it.
  """
  @spec get(String.t(), keyword()) :: reading()
  def get(repo, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &now_ms/0)

    case :ets.lookup(@table, repo) do
      [{^repo, overview, expires_at}] when expires_at > now ->
        {:ok, overview}

      [{^repo, overview, _expired}] ->
        refresh_unless_backing_off(repo, failure(repo), now)
        {:ok, overview}

      [] ->
        failure = failure(repo)
        refresh_unless_backing_off(repo, failure, now)
        unknown(failure)
    end
  end

  @doc """
  Drop everything cached for `repo`: the overview and any failure state. The
  table is global, so a test that fills it cleans up with this.
  """
  @spec forget(String.t()) :: :ok
  def forget(repo) do
    :ets.delete(@table, repo)
    :ets.delete(@table, failure_key(repo))
    :ok
  end

  @doc """
  A fetch failure as one short line for the log and the page. Never the
  response headers or body: they are large, and they can carry authorization
  URLs (the SAML SSO header is one).

  `Custode.BootProjection.short/1` (#477) does the same job for a different
  shape, `{:repository_identity_unavailable, repo, error}`, and names the
  repo inside the line. The reason here stands alone because the log line and
  the panel both already say which repo.

      iex> Custode.GitHub.Cache.short_reason(%GhEx.Error{status: 403, message: "Resource protected by organization SAML enforcement"})
      "HTTP 403: Resource protected by organization SAML enforcement"

      iex> Custode.GitHub.Cache.short_reason(%GhEx.Error{status: 502})
      "HTTP 502"

      iex> Custode.GitHub.Cache.short_reason(%GhEx.Error{message: "Could not resolve to a Repository"})
      "Could not resolve to a Repository"

      iex> Custode.GitHub.Cache.short_reason(:no_github_token)
      ":no_github_token"
  """
  @spec short_reason(term()) :: String.t()
  def short_reason(%GhEx.Error{status: status, message: message}) when is_integer(status) do
    if is_binary(message), do: clip("HTTP #{status}: #{message}"), else: "HTTP #{status}"
  end

  def short_reason(%GhEx.Error{message: message}) when is_binary(message), do: clip(message)

  # Neither a status nor a message: inspecting the struct is the one thing
  # that would put `headers` and `body` in the line.
  def short_reason(%GhEx.Error{}), do: "GitHub API error"

  # The fetcher wraps a response it could not read as `{:unexpected, response}`,
  # and that response can be a whole GraphQL payload.
  def short_reason({:unexpected, _response}), do: "unexpected response"

  def short_reason(reason) when is_binary(reason), do: clip(reason)

  # A transport failure (`%Req.TransportError{}` and the like).
  def short_reason(reason) when is_exception(reason), do: reason |> Exception.message() |> clip()

  def short_reason(reason),
    do: reason |> inspect(limit: 5, printable_limit: @reason_limit) |> clip()

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{in_flight: MapSet.new()}}
  end

  @impl GenServer
  def handle_cast({:refresh, repo}, state) do
    if MapSet.member?(state.in_flight, repo) do
      {:noreply, state}
    else
      cache = self()

      Task.Supervisor.start_child(Custode.TaskSupervisor, fn ->
        send(cache, {:fetched, repo, Custode.GitHub.fetcher().fetch(repo)})
      end)

      {:noreply, %{state | in_flight: MapSet.put(state.in_flight, repo)}}
    end
  end

  @impl GenServer
  def handle_info({:fetched, repo, {:ok, overview}}, state) do
    if failure(repo) do
      :ets.delete(@table, failure_key(repo))
      Logger.info("github overview fetch recovered for #{repo}")
    end

    :ets.insert(@table, {repo, overview, now_ms() + ttl_ms()})
    Custode.PubSubBridge.broadcast({:repo_overview, repo})
    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, repo)}}
  end

  def handle_info({:fetched, repo, {:error, error}}, state) do
    reason = short_reason(error)
    previous = failure(repo)
    failures = failures(previous) + 1

    :ets.insert(@table, {failure_key(repo), reason, now_ms() + retry_ms(failures), failures})

    if previous == nil do
      Logger.warning(
        "github overview fetch failing for #{repo}: #{reason} (retrying on a backoff)"
      )
    end

    # A page re-pulls only when what it would draw changed: the first failure
    # ends its loading state, and a different reason replaces the line. A
    # repeat of the same failure changes nothing on screen.
    if reason_of(previous) != reason, do: Custode.PubSubBridge.broadcast({:repo_overview, repo})

    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, repo)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- failure rows ------------------------------------------------------------
  #
  # `{{:failure, repo}, reason, retry_at, failures}` beside the overview row
  # `{repo, overview, expires_at}`, so a repo can hold both: a stale overview
  # to serve and the record that refreshing it is failing.

  defp failure_key(repo), do: {:failure, repo}

  defp failure(repo) do
    case :ets.lookup(@table, failure_key(repo)) do
      [{_key, reason, retry_at, failures}] -> {reason, retry_at, failures}
      [] -> nil
    end
  end

  defp failures(nil), do: 0
  defp failures({_reason, _retry_at, failures}), do: failures

  defp reason_of(nil), do: nil
  defp reason_of({reason, _retry_at, _failures}), do: reason

  defp unknown(nil), do: :loading
  defp unknown({reason, _retry_at, _failures}), do: {:error, reason}

  defp refresh_unless_backing_off(_repo, {_reason, retry_at, _failures}, now)
       when retry_at > now,
       do: :ok

  defp refresh_unless_backing_off(repo, _failure, _now),
    do: GenServer.cast(__MODULE__, {:refresh, repo})

  defp retry_ms(1),
    do: Application.get_env(:custode, :github_retry_first_ms, @default_retry_first_ms)

  defp retry_ms(_consecutive),
    do: Application.get_env(:custode, :github_retry_repeat_ms, @default_retry_repeat_ms)

  # One line, whatever the source: a transport message can carry newlines.
  defp clip(text), do: text |> String.replace(~r/\s+/, " ") |> String.slice(0, @reason_limit)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp ttl_ms, do: Application.get_env(:custode, :github_ttl_ms, @default_ttl_ms)
end
