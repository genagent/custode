defmodule Custode.Feed do
  @moduledoc """
  The activity feed: a telemetry sink appending one JSON line per noteworthy
  event to `feed.jsonl`. Noteworthy means signal, not spam: finished turns
  (with the sweep report and spend), failed turns, the two gated states
  (with the action/question the agent is blocked on), and pause/resume.

  Monitor it however you like -- `Custode.feed()` pretty-prints the tail,
  `tail -f feed.jsonl | jq .` streams it, and anything downstream (a Phoenix
  UI over PubSub, an ntfy.sh push for mobile) is one more consumer of the
  same telemetry.

  Events that need a human -- `needs_approval`, `needs_input`, `turn_failed`
  -- also raise a macOS desktop notification (`osascript`), controlled by
  `config :custode, desktop_notifications: true`.
  """

  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception]
  ]

  def attach do
    :telemetry.attach_many("custode-feed", @events, &__MODULE__.handle_event/4, nil)
  end

  def path, do: Application.get_env(:custode, :feed_path, "feed.jsonl")

  @doc "The last `n` feed entries as maps, oldest first."
  def tail(n \\ 20) do
    case File.read(path()) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.take(-n)
        |> Enum.map(&Jason.decode!/1)

      {:error, :enoent} ->
        []
    end
  end

  def handle_event([:oban_claude, :run, :stop], measurements, meta, _config) do
    out = ObanClaude.structured(meta.result) || %{}

    write(%{
      event: "turn",
      agent: agent_of(meta),
      directive: out["directive"],
      summary: out["summary"] || String.slice(meta.result.result || "", 0, 160),
      cost_usd: Float.round(measurements.cost_usd, 4)
    })
  end

  def handle_event([:oban_claude, :run, :exception], _measurements, meta, _config) do
    kind = if is_struct(meta.error), do: meta.error.kind, else: :unknown
    write(%{event: "turn_failed", agent: agent_of(meta), kind: kind}, notify: true)
  end

  def handle_event([:oban_claude, :agent, :transition], _measurements, meta, _config) do
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
    File.write!(path(), encoded <> "\n", [:append])
    # the dashboard's live stream: same shape as tail/1 (string keys)
    Custode.PubSubBridge.broadcast({:feed_entry, Jason.decode!(encoded)})
    if opts[:notify], do: notify(entry)
    :ok
  end

  # Fire-and-forget so a slow osascript never blocks the agent process the
  # telemetry handler runs in.
  defp notify(entry) do
    if Application.get_env(:custode, :desktop_notifications, true) and
         match?({:unix, :darwin}, :os.type()) do
      body = entry[:action] || entry[:question] || to_string(entry[:kind] || entry.event)
      title = "custode: #{entry.agent} #{entry.event}"

      script =
        "display notification #{inspect(String.slice(body, 0, 140))} " <>
          "with title #{inspect(title)} sound name \"Glass\""

      Task.start(fn -> System.cmd("osascript", ["-e", script], stderr_to_stdout: true) end)
    end

    :ok
  end

  defp agent_of(%{job: %{meta: %{"agent_id" => id}}}), do: id
  defp agent_of(_meta), do: "?"
end
