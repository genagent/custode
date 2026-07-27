defmodule Custode.Attention.Verify do
  @moduledoc """
  Live check verification for the one promotion that cannot afford to be
  wrong (#317).

  `Custode.Attention.Fleet` reads the cached GitHub overview, and a cache is
  stale by design. In `:watching` that is fine: a wrong row sits in a group
  nobody is expected to act on this minute. In `:needs_you` it is not, because
  the whole value of that group is that everything in it is real -- one stale
  entry teaches the operator to skim it, and a skimmed needs-you group is no
  better than the flat grid #296 replaced.

  So the read is two-tier. The cheap cached signal decides `:watching`;
  promotion to `:needs_you` asks GitHub. Escalation needs a disownment to
  already exist, so verification is rare by construction and costs nothing at
  fleet scale.

  Asking GitHub must not happen on the resolver's path, which runs on every
  page render. `verdict/2` therefore answers from ETS and kicks an async
  re-check on a miss, exactly as `Custode.GitHub.Cache` does:

    * `:red` -- GitHub confirms a failing check; the promotion is honest.
    * `:cleared` -- the live checks are not failing. The cached signal is
      stale, the PR was presumably fixed, and the honest answer is to drop the
      signal rather than keep it and mark it doubtful.
    * `:unverified` -- nothing known yet, and a re-check is now in flight. The
      caller falls back to the cached tier, so the row lands in `:watching`
      until the truth arrives.

  A landed verdict broadcasts `{:repo_overview, repo}`, the message the fleet
  surfaces already re-pull on, so the next resolve sees it.
  """

  use GenServer

  require Logger

  @table :custode_check_verdicts
  @default_ttl_ms 120_000

  # A live check run is red only when it has FINISHED failing. An in-flight
  # check is not a failure, and neither is a skipped or neutral one -- treating
  # either as red is the false needs-you entry this module exists to prevent.
  @failing ~w(failure timed_out action_required startup_failure)

  @type verdict :: :red | :cleared | :unverified

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  What GitHub says about `number`'s checks: `:red`, `:cleared`, or
  `:unverified` with a re-check kicked. Never blocks on the network.
  """
  @spec verdict(String.t(), integer()) :: verdict()
  def verdict(repo, number) when is_binary(repo) and is_integer(number) do
    key = {repo, number}
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@table, key) do
      [{^key, verdict, expires_at}] when expires_at > now ->
        verdict

      # A stale verdict still beats guessing: serve it and re-check behind it.
      [{^key, verdict, _expired}] ->
        GenServer.cast(__MODULE__, {:verify, repo, number})
        verdict

      [] ->
        GenServer.cast(__MODULE__, {:verify, repo, number})
        :unverified
    end
  end

  @doc "Forget every verdict. For tests, and for a caller that wants a fresh read."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  @impl GenServer
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, %{in_flight: MapSet.new()}}
  end

  @impl GenServer
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, %{state | in_flight: MapSet.new()}}
  end

  @impl GenServer
  def handle_cast({:verify, repo, number}, state) do
    key = {repo, number}

    if MapSet.member?(state.in_flight, key) do
      {:noreply, state}
    else
      verifier = self()

      Task.Supervisor.start_child(Custode.TaskSupervisor, fn ->
        send(verifier, {:verified, repo, number, Custode.Repository.pr_checks(repo, number)})
      end)

      {:noreply, %{state | in_flight: MapSet.put(state.in_flight, key)}}
    end
  end

  @impl GenServer
  def handle_info({:verified, repo, number, {:ok, %{checks: checks}}}, state) do
    expires_at = System.monotonic_time(:millisecond) + ttl_ms()
    :ets.insert(@table, {{repo, number}, verdict_of(checks), expires_at})
    Custode.PubSubBridge.broadcast({:repo_overview, repo})
    {:noreply, done(state, repo, number)}
  end

  # An unreachable (or unserved) repository records nothing: the absence of a
  # verdict keeps the row in :watching, which is the safe half. The next read
  # retries.
  def handle_info({:verified, repo, number, other}, state) do
    Logger.debug("check verification failed for #{repo}##{number}: #{inspect(other)}")
    {:noreply, done(state, repo, number)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp done(state, repo, number),
    do: %{state | in_flight: MapSet.delete(state.in_flight, {repo, number})}

  defp verdict_of(checks) do
    if Enum.any?(checks, &(to_string(&1[:conclusion]) in @failing)), do: :red, else: :cleared
  end

  defp ttl_ms, do: Application.get_env(:custode, :check_verdict_ttl_ms, @default_ttl_ms)
end
