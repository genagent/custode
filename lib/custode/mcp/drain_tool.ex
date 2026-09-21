defmodule Custode.MCP.Tools.Drain do
  @moduledoc """
  Graceful drain (#132), the async shape the PR #145 review settled: pause
  the executing queues NOW, reply NOW, and let the wait-then-stop run in the
  background. A synchronous drain would lie at every real use -- the CLI's
  30-second receive window cannot hold a multi-minute turn, and `System.stop`
  drops the connection mid-reply anyway.

  The reply reports what was paused and how many turns are still executing;
  from there the FEED carries the story (the `paused` entry from
  `Custode.drain/1`, then either the VM stopping or a `drain_timeout`
  entry naming the stuck jobs). On timeout the queues STAY paused --
  deliberately, since resuming would reopen the very race the drain exists
  to close; `Oban.resume_queue/1` per queue is the abort path.

  Operator-only for now: the caretaker's restart orders get this tool as a
  separate, deliberate grant later. A routine or sub-agent calling drain is
  refused at the verb.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Operator.Actions

  schema do
    field(:timeout_ms, :integer,
      description: "give up (leaving queues paused) after this many ms; default unbounded"
    )
  end

  @impl true
  def execute(params, frame) do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} ->
        case Actions.drain(timeout_ms: params[:timeout_ms]) do
          {:ok, executing} ->
            reply(frame, %{
              draining: true,
              executing: executing,
              note:
                "queues paused; the server stops when the #{executing} executing turn(s) finish. " <>
                  "Progress lands in the feed; on timeout the queues stay paused (resume_queue to abort)."
            })

          {:error, reason} ->
            fail(frame, "drain admission failed: #{reason}")
        end

      _agent ->
        fail(frame, "identity: drain is the operator's; agents propose restarts, humans run them")
    end
  end
end
