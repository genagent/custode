defmodule Custode.Instance do
  @moduledoc """
  The single-instance guard (#77).

  Two custode servers on one SQLite db both run Oban: at the minute boundary
  both crons insert, and the claim-race executes jobs twice -- a doubled TICK
  means real spend and possibly duplicate gates. This happens on a restart
  when the new server boots INSIDE the old one's graceful-shutdown window:
  the listening ports free early in the supervision teardown, but Oban stops
  LAST and keeps polling through the MCP-session drain.

  The honest fix is a heartbeat, not a port probe (the ports are already free
  during exactly the dangerous window). A singleton `instance` row carries the
  live server's identity (`os_pid`, the real per-boot identity -- the node name
  is `nonode@nohost` for every boot) and a `beat_at` timestamp this process
  refreshes every 10s. On boot `claim/2` runs before Oban starts:

    * free / stale / our own row  -> claim it and start;
    * a FRESH heartbeat we do not own -> refuse to boot (`init/1` returns
      `{:stop, ...}`, which aborts `Custode.Application.start`);
    * `--takeover` (env `CUSTODE_TAKEOVER=1`) -> seize it regardless, the
      escape hatch for a wedged predecessor.

  A crash leaves the row behind, but its heartbeat goes stale within seconds,
  so the next boot reclaims it -- no manual cleanup.
  """

  use GenServer

  require Logger
  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  @key "singleton"
  @beat_interval_ms 10_000
  # A heartbeat is "live" only within this window. It must exceed the beat
  # interval with headroom so a momentarily-slow beat is not misread as a
  # dead instance, yet stay short enough that a crashed server's row frees
  # quickly. 3x the interval.
  @stale_after_ms 30_000

  defmodule Row do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:key, :string, autogenerate: false}
    schema "instance" do
      field(:node, :string)
      field(:os_pid, :string)
      field(:beat_at, :utc_datetime_usec)
    end
  end

  @doc "Start the guard. Aborts the boot when a live foreign instance holds the row."
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl GenServer
  def init(opts) do
    key = Keyword.get(opts, :key, @key)
    mine = Keyword.get(opts, :os_pid, os_pid())

    case claim(key, opts) do
      :ok ->
        # Trap exits so a graceful supervisor `:shutdown` runs terminate/2
        # instead of killing us outright -- that is where we release the row.
        Process.flag(:trap_exit, true)
        Process.send_after(self(), :beat, beat_interval_ms(opts))
        {:ok, %{key: key, os_pid: mine, opts: opts}}

      {:error, {:occupied, holder}} ->
        Logger.error(
          "another custode instance holds a fresh heartbeat " <>
            "(node=#{holder.node} os_pid=#{holder.os_pid} beat_at=#{holder.beat_at}); " <>
            "refusing to boot. Set CUSTODE_TAKEOVER=1 to seize it."
        )

        {:stop, {:instance_conflict, holder}}
    end
  end

  @impl GenServer
  def handle_info(:beat, state) do
    write(state.key, DateTime.utc_now())
    Process.send_after(self(), :beat, beat_interval_ms(state.opts))
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Release the row eagerly on a graceful stop so a same-second restart
    # does not hit our own still-fresh heartbeat and refuse to boot. Guard on
    # os_pid: if a takeover seized the row while we ran, it now belongs to the
    # usurper and is not ours to delete. Crash paths skip this and rely on the
    # heartbeat going stale, which is exactly right.
    case holder(state.key) do
      %Row{os_pid: os_pid} when os_pid == state.os_pid -> purge(state.key)
      _ -> :ok
    end

    :ok
  end

  @doc """
  Claim the instance row for `key`. Returns `:ok` when the row is free, its
  heartbeat is stale, it is our own, or takeover is set; `{:error, {:occupied,
  holder}}` when a fresh heartbeat owned by another boot already holds it.

  Options (test seams): `:now`, `:takeover`, `:stale_after_ms`, `:os_pid`.
  """
  def claim(key \\ @key, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    mine = Keyword.get(opts, :os_pid, os_pid())

    case Repo.get(Row, key) do
      nil ->
        write(key, now, mine)
        :ok

      %Row{} = holder ->
        cond do
          holder.os_pid == mine ->
            write(key, now, mine)
            :ok

          Keyword.get(opts, :takeover, takeover?()) ->
            Logger.warning(
              "--takeover: seizing instance row from node=#{holder.node} os_pid=#{holder.os_pid}"
            )

            write(key, now, mine)
            :ok

          fresh?(holder.beat_at, now, Keyword.get(opts, :stale_after_ms, @stale_after_ms)) ->
            {:error, {:occupied, holder}}

          true ->
            write(key, now, mine)
            :ok
        end
    end
  end

  @doc "The live holder row for `key`, or `nil`."
  def holder(key \\ @key), do: Repo.get(Row, key)

  defp write(key, now, mine \\ nil) do
    os = mine || os_pid()

    Repo.insert!(
      %Row{key: key, node: to_string(node()), os_pid: os, beat_at: now},
      on_conflict: [set: [node: to_string(node()), os_pid: os, beat_at: now]],
      conflict_target: :key
    )

    :ok
  end

  defp fresh?(beat_at, now, stale_after_ms) do
    DateTime.diff(now, beat_at, :millisecond) < stale_after_ms
  end

  defp os_pid, do: System.pid()

  defp takeover? do
    case System.get_env("CUSTODE_TAKEOVER") do
      nil -> Application.get_env(:custode, :instance_takeover, false)
      "" -> false
      "0" -> false
      "false" -> false
      _set -> true
    end
  end

  defp beat_interval_ms(opts), do: Keyword.get(opts, :beat_interval_ms, @beat_interval_ms)

  @doc false
  def purge(key \\ @key), do: Repo.delete_all(from(r in Row, where: r.key == ^key))
end
