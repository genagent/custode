defmodule Custode.Availability.Probe do
  @moduledoc """
  Asks Claude how much of the plan is used (#458, #524).

  The primary source is Claude's OAuth usage endpoint. It reads Claude Code's
  local access token for one request and costs no model quota. Because that
  endpoint is undocumented, any missing credential, refusal, transport error
  or unrecognized response falls back to the sealed stream probe below.

  Claude publishes its rate-limit state as an event INSIDE a run's stream:

      {"type": "rate_limit_event", "rate_limit_info": {"unifiedWindows":
        {"five_hour": {"utilization": 0.12, ...}, "seven_day": {...}}}}

  Observed one-shot execution retains typed rate-limit observations and
  ObanClaude 0.10.1 exposes them on successful and failed run telemetry.
  Custode caches useful observations without starting another model turn.
  Those events have no individual timestamp, so their freshness uses the
  run-start lower bound derived from duration; a long run cannot make early
  evidence look current merely by completing. A newer cached observation wins.

  When no fresh observation exists, the worker still tries OAuth first,
  then one sealed, one-turn haiku query through `ClaudeWrapper.stream/2`.
  Event coverage from ordinary fleet work remains a prerequisite for any
  later decision to remove this fallback. This worker skips both collection
  paths when the existing snapshot is fresh.

  A probe that fails records nothing and says so in the log. Absence advises
  proceeding (`Custode.Availability`), so a broken probe cannot become an
  outage; it becomes a header with no usage in it.
  """

  use Oban.Worker, queue: :sensors, max_attempts: 1

  require Logger

  alias Custode.Availability
  alias Custode.Availability.ClaudeOAuthUsage
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
    oauth_fun = Application.get_env(:custode, :usage_oauth_fun, &ClaudeOAuthUsage.collect/1)

    case oauth_fun.(options) do
      {:ok, snapshot} ->
        changed(snapshot)

      {:error, reason} ->
        Logger.warning("OAuth usage unavailable (#{reason_label(reason)}); using sealed probe")
        stream_probe(options)
    end
  rescue
    _error ->
      Logger.warning("OAuth usage collector failed; using sealed probe")
      stream_probe(options)
  end

  defp stream_probe(options) do
    stream_fun = Application.get_env(:custode, :usage_probe_fun, &stream/0)

    case Enum.find(stream_fun.(), &rate_limit_event?/1) do
      nil ->
        Logger.warning("usage probe: the run carried no rate_limit_event")
        {:error, :no_rate_limit_event}

      event ->
        with {:ok, snapshot} <- Claude.observe(payload(event), options) do
          changed(snapshot)
        end
    end
  rescue
    error ->
      Logger.warning("usage probe failed: #{Exception.message(error)}")
      {:error, :probe_failed}
  end

  defp changed(snapshot) do
    Custode.PubSubBridge.broadcast({:usage_changed, @provider})
    {:ok, snapshot}
  end

  defp reason_label({:http_status, status}) when is_integer(status), do: "HTTP #{status}"
  defp reason_label(:credential_not_found), do: "no credential"
  defp reason_label(:credential_unreadable), do: "credential unreadable"
  defp reason_label(:invalid_credentials), do: "invalid credential shape"
  defp reason_label(:credential_rejected), do: "credential rejected"
  defp reason_label(:rate_limited), do: "rate limited"
  defp reason_label(:request_failed), do: "request failed"
  defp reason_label(:unexpected_oauth_usage_payload), do: "unexpected response"
  defp reason_label(_reason), do: "collector failed"

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
