defmodule Custode.Feed do
  @moduledoc """
  The activity feed: a telemetry sink recording one entry per noteworthy
  event. Noteworthy means signal, not spam: finished turns (with the sweep
  report and spend), failed turns, the two gated states (with the
  action/question the agent is blocked on), and pause/resume.

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

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-feed", @events, &__MODULE__.handle_event/4, nil)
  end

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

  # :telemetry DETACHES a handler that raises -- one transient Repo/file
  # error would silently kill this pipeline until restart (audit
  # 2026-07-21). Never raise out of a handler.
  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      require Logger

      Logger.error("Custode.Feed handler error (kept attached): " <> Exception.message(exception))

      :ok
  end

  defp do_handle_event([:oban_claude, :run, :stop], measurements, meta, _config) do
    out = ObanClaude.structured(meta.result) || %{}
    usage = ClaudeWrapper.Result.usage(meta.result)

    %{
      event: "turn",
      agent: agent_of(meta),
      directive: out["directive"],
      summary: out["summary"] || String.slice(meta.result.result || "", 0, 160),
      # An operator-origin turn is conversation, not telemetry (#138): the
      # full answer persists on the entry so a restart cannot strand it in
      # process memory. Sweep turns stay summary-only.
      response: prompt_response(meta),
      cost_usd: Float.round(measurements.cost_usd, 4),
      tokens: usage && usage.total
    }
    |> put_touched(out)
    |> write()
  end

  defp do_handle_event([:oban_claude, :run, :exception], _measurements, meta, _config) do
    {kind, detail} = error_facts(meta.error)

    write(%{event: "turn_failed", agent: agent_of(meta), kind: kind, detail: detail},
      notify: true
    )
  end

  defp do_handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
    # The registry is already synced when transition telemetry fires, so the
    # gated payload is atomically readable here.
    case {meta.from, meta.to} do
      {_from, :awaiting_permission} ->
        write(%{event: "needs_approval", agent: meta.agent_id, action: gated(meta.agent_id)},
          notify: true
        )

      {_from, :waiting_for_user} ->
        write(%{event: "needs_input", agent: meta.agent_id, question: gated(meta.agent_id)},
          notify: true
        )

      {_from, :paused} ->
        write(%{event: "paused", agent: meta.agent_id})

      {:paused, :idle} ->
        write(%{event: "resumed", agent: meta.agent_id})

      _other ->
        :ok
    end
  end

  # The schema'd sweep epilogue (#120 slice 2): what the turn touched arrives
  # as typed arrays, so cards and metrics read fields instead of fishing
  # numbers out of the prose summary. Absent -- or the wrong type, which a
  # model can still send past a schema -- means the key does not appear at
  # all, so an unschema'd turn's entry keeps exactly its old shape.
  defp put_touched(entry, out) do
    entry
    |> maybe_put(:prs, numbers(out["prs"]))
    |> maybe_put(:issues_touched, numbers(out["issues_touched"]))
  end

  defp maybe_put(entry, _key, []), do: entry
  defp maybe_put(entry, key, numbers), do: Map.put(entry, key, numbers)

  defp numbers(values) when is_list(values), do: Enum.filter(values, &is_integer/1)
  defp numbers(_other), do: []

  # The Error struct carries the actual diagnosis (message/stderr/exit code);
  # dropping it cost a debugging session (quakes' command_failed). Keep a
  # bounded slice in the feed entry.
  defp error_facts(%ClaudeWrapper.Error{} = error) do
    detail =
      [
        error.message,
        error.stderr && String.slice(error.stderr, 0, 300),
        error.stdout && String.slice(error.stdout, 0, 300)
      ]
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.join(" -- ")

    detail = if error.exit_code, do: "exit #{error.exit_code}: #{detail}", else: detail
    {error.kind, presence(detail)}
  end

  defp error_facts(other), do: {:unknown, presence(inspect(other))}

  defp presence(""), do: nil
  defp presence(string), do: string

  defp gated(agent_id) do
    case ObanClaude.Agent.status(agent_id) do
      {:ok, {:awaiting_permission, %{description: description}}} -> description
      {:ok, {:waiting_for_user, question}} -> question
      _other -> nil
    end
  end

  defp write(entry, opts \\ []) do
    entry = Map.put(entry, :at, DateTime.to_iso8601(DateTime.utc_now()))
    encoded = Jason.encode!(entry)
    # the canonical shape consumers see: string keys, JSON-clean
    decoded = Jason.decode!(encoded)

    {:ok, _row} = insert(decoded, encoded)
    mirror(encoded)
    Custode.PubSubBridge.broadcast({:feed_entry, decoded})
    Custode.Ntfy.publish(decoded)
    if opts[:notify], do: notify(entry)
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

  # Fire-and-forget so a slow notifier never blocks the agent process the
  # telemetry handler runs in. terminal-notifier (brew) is preferred: clicking
  # the notification deep-links to the agent's dashboard page, where
  # osascript's display notification can only focus Script Editor.
  defp notify(entry) do
    if Application.get_env(:custode, :desktop_notifications, true) and
         match?({:unix, :darwin}, :os.type()) do
      body = entry[:action] || entry[:question] || to_string(entry[:kind] || entry.event)
      title = "custode: #{entry.agent} #{entry.event}"
      url = dashboard_url(entry)

      Task.start(fn -> deliver_notification(title, body, url, entry.agent) end)
    end

    :ok
  end

  defp deliver_notification(title, body, url, agent) do
    case System.find_executable("terminal-notifier") do
      nil ->
        script =
          "display notification #{inspect(String.slice(body, 0, 140))} " <>
            "with title #{inspect(title)} sound name \"Glass\""

        System.cmd("osascript", ["-e", script], stderr_to_stdout: true)

      notifier ->
        args = [
          "-title",
          title,
          "-message",
          String.slice(body, 0, 240),
          "-open",
          url,
          "-sound",
          "Glass",
          "-group",
          "custode-#{agent}"
        ]

        System.cmd(notifier, args, stderr_to_stdout: true)
    end
  end

  defp dashboard_url(entry), do: Custode.Ntfy.dashboard_url(entry[:agent])

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"

  # The full response text for an operator-origin turn, nil otherwise.
  # Capped generously: prompt answers are prose, not payloads, and the cap
  # only guards against a pathological turn flooding a feed row.
  @response_cap 16_384
  defp prompt_response(%{job: %{meta: %{"origin" => "operator"}}, result: result}) do
    case result.result do
      text when is_binary(text) and text != "" -> String.slice(text, 0, @response_cap)
      _other -> nil
    end
  end

  defp prompt_response(_meta), do: nil
end
