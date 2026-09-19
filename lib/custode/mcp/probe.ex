defmodule Custode.MCP.Probe do
  @moduledoc """
  The boot-order gate for issue #4: the `:ticks` queue does not start until
  a loopback MCP `initialize` succeeds.

  The recurring failure was always the FIRST agent sweep after a server
  restart: the claude CLI would race the MCP session layer coming up, fail
  to connect, and drop the custode server for that whole session -- the
  agent then swept without its notebook. Holding the ticks queue until the
  HTTP surface demonstrably answers removes the race mechanically; agent
  turns cannot exist before a tick does.

  Fail-open: if the probe never succeeds within the window, the queue starts
  anyway with a loud log -- a broken MCP server should degrade sweeps, not
  silence the fleet.
  """

  require Logger

  alias Custode.MCP.Identity

  @attempts 60
  @interval_ms 1_000

  def child_spec(_opts) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :transient}
  end

  @doc false
  def run do
    queues = Application.get_env(:custode, :oban_queues, agents: 3, ticks: 1, sensors: 2)

    case Keyword.get(queues, :ticks) do
      nil -> :ok
      limit -> gate_ticks(limit)
    end
  end

  # Doctor first (#15): with no claude binary or no auth, every sweep would
  # fail identically -- withhold ticks entirely and say so loudly. The MCP
  # probe stays fail-open (#4): a broken MCP surface only degrades sweeps.
  defp gate_ticks(limit) do
    case doctor() do
      :ok ->
        case await_ready(@attempts) do
          :ok ->
            Logger.info("MCP surface answered; starting the ticks queue")

          :timeout ->
            Logger.warning(
              "MCP probe never succeeded after #{@attempts}s; starting ticks anyway (#4)"
            )
        end

        discard_stale_ticks()
        :ok = Oban.start_queue(queue: :ticks, limit: limit)

      {:error, report} ->
        Logger.error("claude doctor failed; ticks withheld: #{report}")

        Custode.Feed.record(
          %{
            event: "doctor_failed",
            agent: "custode",
            action: report <> " -- ticks withheld; fix and restart"
          },
          notify: true
        )

        :ok
    end
  end

  # Ticks inserted while a previous boot had the queue withheld (or while a
  # drain had it paused) are still `available`, and starting the queue would
  # run every one of them (#442). Discard them first, and say so: the operator
  # is usually watching this boot to confirm it is clean.
  defp discard_stale_ticks do
    case Custode.Ticks.discard_stale() do
      0 ->
        :ok

      count ->
        Logger.info("discarded #{count} stale ticks before starting the queue (#442)")

        Custode.Feed.record(%{
          event: "stale_ticks_discarded",
          agent: "custode",
          summary: "discarded #{count} ticks that went stale while the queue was not running"
        })

        :ok
    end
  end

  @doc """
  The claude preflight (#15): binary present and usable, authenticated.
  `:ok`, or `{:error, report}` naming every failed check.
  """
  def doctor do
    checks = [
      {"claude binary/version", doctor_fun().(:version)},
      {"claude auth", doctor_fun().(:auth)}
    ]

    case for {label, {:error, reason}} <- checks, do: "#{label}: #{inspect(reason)}" do
      [] -> :ok
      failures -> {:error, Enum.join(failures, "; ")}
    end
  end

  defp doctor_fun do
    Application.get_env(:custode, :doctor_fun, fn
      :version -> ClaudeWrapper.version()
      :auth -> ClaudeWrapper.auth_status()
    end)
  end

  @doc "One loopback initialize attempt against the running MCP server."
  def ready? do
    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: %{
        protocolVersion: "2025-06-18",
        capabilities: %{},
        clientInfo: %{name: "custode-probe", version: "0"}
      }
    }

    headers =
      case Identity.operator_token() do
        {:ok, token} ->
          [
            {"accept", "application/json, text/event-stream"},
            {"authorization", "Bearer " <> token}
          ]

        {:error, _reason} ->
          [{"accept", "application/json, text/event-stream"}]
      end

    case Req.post(Custode.MCP.url(),
           json: body,
           headers: headers,
           retry: false,
           connect_options: [timeout: 1_000],
           receive_timeout: 2_000
         ) do
      {:ok, %Req.Response{status: 200}} -> true
      _not_ready -> false
    end
  end

  @doc false
  def await_ready(attempts_left) when attempts_left <= 0, do: :timeout

  def await_ready(attempts_left) do
    if ready?() do
      :ok
    else
      Process.sleep(@interval_ms)
      await_ready(attempts_left - 1)
    end
  end
end
