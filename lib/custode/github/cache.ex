defmodule Custode.GitHub.Cache do
  @moduledoc """
  TTL cache over `Custode.GitHub` fetches, tuned for LiveView reads:

    * a fresh hit answers from ETS;
    * a stale hit answers from ETS AND kicks an async refresh (stale beats
      blank -- the panel updates when the fetch lands);
    * a cold miss answers `:loading` and kicks the refresh.

  Refreshes are deduplicated (one in flight per repo), run in a `Task` so a
  GitHub hiccup never takes the cache down, and broadcast
  `{:repo_overview, repo}` on the agents topic on success. A failed refresh
  just logs -- the next read retries.
  """

  use GenServer

  require Logger

  @table :custode_github_cache
  @default_ttl_ms 120_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "See `Custode.GitHub.overview/1`."
  def get(repo) do
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, repo) do
      [{^repo, overview, expires_at}] when expires_at > now ->
        {:ok, overview}

      [{^repo, overview, _expired}] ->
        GenServer.cast(__MODULE__, {:refresh, repo})
        {:ok, overview}

      [] ->
        GenServer.cast(__MODULE__, {:refresh, repo})
        :loading
    end
  end

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
    expires_at = System.monotonic_time(:millisecond) + ttl_ms()
    :ets.insert(@table, {repo, overview, expires_at})
    Custode.PubSubBridge.broadcast({:repo_overview, repo})
    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, repo)}}
  end

  def handle_info({:fetched, repo, {:error, reason}}, state) do
    Logger.warning("github overview fetch failed for #{repo}: #{inspect(reason)}")
    {:noreply, %{state | in_flight: MapSet.delete(state.in_flight, repo)}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp ttl_ms, do: Application.get_env(:custode, :github_ttl_ms, @default_ttl_ms)
end
