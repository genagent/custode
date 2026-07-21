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

  @attempts 60
  @interval_ms 1_000

  def child_spec(_opts) do
    %{id: __MODULE__, start: {Task, :start_link, [&run/0]}, restart: :transient}
  end

  @doc false
  def run do
    queues = Application.get_env(:custode, :oban_queues, agents: 3, ticks: 1, sensors: 2)

    case Keyword.get(queues, :ticks) do
      nil ->
        :ok

      limit ->
        case await_ready(@attempts) do
          :ok ->
            Logger.info("MCP surface answered; starting the ticks queue")

          :timeout ->
            Logger.warning(
              "MCP probe never succeeded after #{@attempts}s; starting ticks anyway (#4)"
            )
        end

        :ok = Oban.start_queue(queue: :ticks, limit: limit)
    end
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

    case Req.post(Custode.MCP.url(),
           json: body,
           headers: [{"accept", "application/json, text/event-stream"}],
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
