defmodule Custode.Availability.Probe do
  @moduledoc """
  Asks Claude how much of the plan is used, by running the smallest turn there
  is (#458).

  Claude publishes its rate-limit state as an event INSIDE a run's stream:

      {"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows":
        {"five_hour": {"utilization": 0.12, ...}, "seven_day": {...}}}}

  The fleet's real turns cannot see it. The engine runs
  `ClaudeWrapper.query/2`, which asks the CLI for one JSON result and never
  sees the stream. Until the engine surfaces the event from real turns, this
  worker runs one sealed, one-turn haiku query through
  `ClaudeWrapper.stream/2`, takes the event out of the stream, and hands it to
  `Custode.Availability.Collectors.Claude`.

  The collector's moduledoc says there is no zero-work probe to call. That is
  true; this is a near-zero one, and on a Max plan it is the cheapest thing
  the fleet does all day. It still skips itself when the snapshot is fresh, so
  the day real turns start feeding the collector this becomes a no-op that can
  be deleted.

  A probe that fails records nothing and says so in the log. Absence advises
  proceeding (`Custode.Availability`), so a broken probe cannot become an
  outage; it becomes a header with no usage in it.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  require Logger

  alias Custode.Availability
  alias Custode.Availability.Collectors.Claude

  @provider "claude"
  @prompt "Reply with the single word: ok"

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    run()
    :ok
  end

  @doc """
  Probe unless the snapshot is already fresh. Returns `:fresh` (skipped),
  `{:ok, snapshot}`, or `{:error, reason}`.
  """
  @spec run(keyword()) :: :fresh | {:ok, Availability.Snapshot.t()} | {:error, term()}
  def run(options \\ []) do
    if fresh?(options), do: :fresh, else: probe(options)
  end

  defp fresh?(options) do
    not Keyword.get(options, :force, false) and
      Availability.usage(@provider, options).freshness == :fresh
  end

  defp probe(options) do
    stream_fun = Application.get_env(:custode, :usage_probe_fun, &stream/0)

    case Enum.find(stream_fun.(), &rate_limit_event?/1) do
      nil ->
        Logger.warning("usage probe: the run carried no rate_limit_event")
        {:error, :no_rate_limit_event}

      event ->
        with {:ok, snapshot} <- Claude.observe(payload(event), options) do
          Custode.PubSubBridge.broadcast({:usage_changed, @provider})
          {:ok, snapshot}
        end
    end
  rescue
    error ->
      Logger.warning("usage probe failed: #{Exception.message(error)}")
      {:error, :probe_failed}
  end

  # Sealed (`hermetic: :full`): no ambient CLAUDE.md, skills, or MCP servers,
  # so the turn is as small as a turn gets and cannot touch anything.
  defp stream do
    ClaudeWrapper.stream(@prompt,
      model: "haiku",
      max_turns: 1,
      hermetic: :full,
      working_dir: System.tmp_dir!()
    )
  end

  defp rate_limit_event?(%{type: "rate_limit_event"}), do: true
  defp rate_limit_event?(%{"type" => "rate_limit_event"}), do: true
  defp rate_limit_event?(_event), do: false

  defp payload(%{data: data}) when is_map(data), do: data
  defp payload(event) when is_map(event), do: event
end
