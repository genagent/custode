defmodule Custode.Feed do
  @moduledoc """
  The activity feed STORE (#92 item 5): records in, queries out. Telemetry
  ingestion lives in `Custode.Feed.Ingest`; human-facing notification
  dispatch lives in `Custode.Feed.Notify`. One entry per noteworthy
  event. Noteworthy means signal, not spam: finished turns (with the sweep
  report and spend), failed turns, the two gated states (with the
  action/question the agent is blocked on), and pause/resume.

  ## Emit-from-birth (#261 / design 004 D1)

  The feed (with the spend ledger and gates table) IS the telemetry substrate:
  everything that adjusts the fleet reads this stream, and nothing keeps
  bespoke counters. The standing rule: **a mechanism ships with its telemetry
  or it does not ship.** A new verb, scheduler, or reconciler records its
  own feed entry (or spend/gate row) from birth -- so the Digest, the
  advisors, and the operator see it without special-casing. Today's emitters
  include finished/failed turns, gated states, pause/resume and budget rails
  (`budget_paused`), drains, sensor and advisor runs, and the repo verbs.

  Entries are RECORDS, so they live in the database (storage doctrine, #43):
  queried per agent, paginated, pruned by retention (#39) instead of file
  rotation. A jsonl mirror is still appended to `:feed_path` for `tail -f`
  ergonomics -- set the path to nil to disable it. `Custode.feed()`
  pretty-prints the tail, and anything downstream (the LiveView over PubSub,
  an ntfy.sh push for mobile) is one more consumer of the same telemetry.

  Events that need a human -- `needs_approval`, `needs_input`, `turn_failed`
  -- also raise a macOS desktop notification, controlled by
  `config :custode, desktop_notifications: true`.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Feed.Notify
  alias Custode.Repo

  defmodule Entry do
    @moduledoc false
    use Ecto.Schema

    schema "feed_entries" do
      field(:agent, :string)
      field(:event, :string)
      field(:entry, :string)
      field(:at, :utc_datetime_usec)
    end
  end

  @gate_events ~w(needs_approval needs_input)

  @doc "The jsonl mirror path (nil disables the mirror)."
  def path, do: Application.get_env(:custode, :feed_path, "feed.jsonl")

  @doc "The size, in bytes, past which the mirror rotates to `path/0 <> \".1\"`."
  def max_bytes, do: Application.get_env(:custode, :feed_max_bytes, 10 * 1024 * 1024)

  @doc "The last `n` feed entries as maps, oldest first."
  def tail(n \\ 20) do
    from(f in Entry, order_by: [desc: f.id], limit: ^n) |> load()
  end

  @doc "The last `n` feed entries for one agent, oldest first."
  def for_agent(agent_id, n \\ 30) do
    from(f in Entry, where: f.agent == ^agent_id, order_by: [desc: f.id], limit: ^n) |> load()
  end

  @doc """
  The most recent entries for one event name, NEWEST FIRST (#178).

  Cards, not a timeline: the freshest entry belongs at the top, which is why
  this is the one read that does not reverse into chronological order.

  Options:

    * `:limit` -- how many entries (default 10)
    * `:agent` -- only this agent's entries (the whole fleet's by default)
    * `:since` -- only entries newer than this many seconds ago
    * `:now` -- reference clock for `:since` (defaults to the current UTC time)

  """
  def recent_by_event(event, opts \\ []) do
    from(f in Entry,
      where: f.event == ^event,
      order_by: [desc: f.id],
      limit: ^Keyword.get(opts, :limit, 10)
    )
    |> scope_agent(opts[:agent])
    |> scope_since(opts[:since], opts[:now])
    |> Repo.all()
    |> Enum.map(&Jason.decode!(&1.entry))
  end

  @doc "Distinct agent ids that have any feed entry, sorted (feed filter, #21)."
  def agents do
    Repo.all(
      from(f in Entry,
        where: not is_nil(f.agent) and f.agent != "?",
        distinct: true,
        order_by: f.agent,
        select: f.agent
      )
    )
  end

  @doc "Agents with any feed entry in the last `seconds` (ghost-tile source, #11)."
  def recent_agents(seconds) do
    cutoff = DateTime.add(DateTime.utc_now(), -seconds)

    Repo.all(
      from(f in Entry,
        where: f.at > ^cutoff and not is_nil(f.agent) and f.agent != "?",
        distinct: true,
        select: f.agent
      )
    )
  end

  @doc """
  Mark the agent's latest unresolved gate card (needs_approval /
  needs_input) as worked: the ORIGINAL entry gains resolved/resolved_at
  in place, so the timeline shows a checkmark chip instead of a stale
  yellow card -- and the update rides the same PubSub topic (the stream
  dom id is stable, so LiveViews replace the card live).
  """
  def mark_gate_resolved(agent_id, resolution) do
    row =
      Repo.one(
        from(f in Entry,
          where:
            f.agent == ^agent_id and f.event in ^@gate_events and
              fragment("json_extract(?, '$.resolved') IS NULL", f.entry),
          order_by: [desc: f.id],
          limit: 1
        )
      )

    case row do
      nil ->
        :ok

      entry ->
        decoded =
          entry.entry
          |> Jason.decode!()
          |> Map.put("resolved", resolution)
          |> Map.put("resolved_at", DateTime.to_iso8601(DateTime.utc_now()))

        encoded = Jason.encode!(decoded)

        Repo.update_all(from(f in Entry, where: f.id == ^entry.id),
          set: [entry: encoded]
        )

        Custode.PubSubBridge.broadcast({:feed_entry, decoded})
        :ok
    end
  end

  @doc "The timestamp of an agent's most recent feed entry (nil if none)."
  def last_activity_at(agent_id) do
    Repo.one(from(f in Entry, where: f.agent == ^agent_id, select: max(f.at)))
  end

  @doc "The most recent feed entry for an agent (its \"last message\"), or nil."
  def last_for(agent_id), do: agent_id |> for_agent(1) |> List.last()

  @doc """
  The agent's last message for display. Gate events (`needs_approval`,
  `needs_input`) only count while the agent is actually still gated --
  otherwise a long-resolved alert masquerades as current state, and the last
  substantive report is the honest answer.
  """
  def last_message(agent_id, currently_gated?) do
    if currently_gated? do
      last_for(agent_id)
    else
      from(f in Entry,
        where: f.agent == ^agent_id and f.event not in @gate_events,
        order_by: [desc: f.id],
        limit: 1
      )
      |> load()
      |> List.last()
    end
  end

  @doc """
  One-time import of a legacy `feed.jsonl` into the table, original
  timestamps preserved. Idempotent enough for its purpose: refuses to run
  unless the table is empty.
  """
  def import_jsonl!(jsonl_path) do
    0 = Repo.aggregate(Entry, :count)

    imported =
      jsonl_path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Enum.count(fn line ->
        decoded = Jason.decode!(line)
        {:ok, _entry} = insert(decoded, line)
        true
      end)

    {:ok, imported}
  end

  @doc """
  Record an app-level event (e.g. `budget_paused`) into the feed, same shape
  and delivery as the telemetry-driven entries. `notify: true` raises the
  desktop notification.
  """
  def record(entry, opts \\ []) when is_map(entry), do: write(entry, opts)

  @prompt_cap 2_000

  @doc """
  The operator prompted an agent (#187): the question lands in the activity
  at SUBMIT time, so the feed shows it while the turn runs and the durable
  record pairs question with answer (#138). Agent-to-sub-agent prompting is
  delegation, not conversation, and stays out of the feed.
  """
  def record_prompted(agent_id, text) do
    write(%{
      event: "prompted",
      agent: agent_id,
      prompt: String.slice(text, 0, @prompt_cap),
      summary: "operator prompted: " <> String.slice(text, 0, 160)
    })
  end

  defp write(entry, opts \\ []) do
    entry = Map.put(entry, :at, DateTime.to_iso8601(DateTime.utc_now()))
    encoded = Jason.encode!(entry)
    # the canonical shape consumers see: string keys, JSON-clean
    decoded = Jason.decode!(encoded)

    {:ok, _row} = insert(decoded, encoded)
    mirror(encoded)
    Custode.PubSubBridge.broadcast({:feed_entry, decoded})
    Notify.dispatch(entry, decoded, notify: opts[:notify])
    :ok
  end

  defp insert(decoded, encoded) do
    at =
      case DateTime.from_iso8601(decoded["at"] || "") do
        {:ok, at, _offset} -> at
        {:error, _reason} -> DateTime.utc_now()
      end

    Repo.insert(%Entry{
      agent: decoded["agent"],
      event: decoded["event"] || "?",
      entry: encoded,
      at: at
    })
  end

  defp load(query) do
    query |> Repo.all() |> Enum.reverse() |> Enum.map(&Jason.decode!(&1.entry))
  end

  defp scope_agent(query, nil), do: query
  defp scope_agent(query, agent), do: from(f in query, where: f.agent == ^agent)

  defp scope_since(query, nil, _now), do: query

  defp scope_since(query, seconds, now) do
    cutoff = DateTime.add(now || DateTime.utc_now(), -seconds)
    from(f in query, where: f.at > ^cutoff)
  end

  defp mirror(encoded) do
    case path() do
      nil ->
        :ok

      mirror_path ->
        max = max_bytes()

        case File.stat(mirror_path) do
          {:ok, %{size: size}} when size >= max ->
            File.rename(mirror_path, mirror_path <> ".1")

          _other ->
            :ok
        end

        File.write!(mirror_path, encoded <> "\n", [:append])
    end
  end
end
