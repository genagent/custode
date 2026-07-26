defmodule Custode.MCP.AskTools do
  @moduledoc """
  The ask surface (#299): one agent-callable tool for filing a non-blocking
  question, and two operator-side tools for reading and closing them.

  Deliberately an operation rather than a lifecycle directive. `ask_user`
  parks the agent (see `Custode.Asks`); `ask_operator` is a tool call that
  returns immediately and leaves the turn to finish.
  """
end

defmodule Custode.MCP.AskTools.AskOperator do
  @moduledoc """
  Ask the operator a question WITHOUT stopping work.

  Use this when a human opinion would help but nothing is blocked: an
  ambiguity worth flagging, a judgment call you made and want checked, a
  threshold that may be miscalibrated. The turn finishes, the next beat runs
  normally, and the answer arrives later as a note in your inbox.

  This is NOT the tool for permission. If nothing should proceed until a human
  decides, raise a gate (structured-output directive `request_permission`)
  instead: that is what blocking is for.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:question, :string,
      required: true,
      description: "the question, in one or two sentences the operator can answer without context"
    )

    field(:detail, :string,
      description: "what you were doing when it came up, for the operator's context"
    )

    field(:agent_id, :string,
      description: "whose question (defaults to the caller; a routine may only file its own)"
    )
  end

  @impl true
  def execute(params, frame) do
    caller = Custode.MCP.caller(frame)
    agent_id = params[:agent_id] || caller.id

    with :ok <- check_self(frame, agent_id),
         {:ok, ask} <- Custode.Asks.ask(agent_id, params.question, detail: params[:detail]) do
      reply(frame, %{
        ask_id: ask.id,
        status: ask.status,
        note: "filed; you are not blocked. The answer will arrive in your inbox."
      })
    else
      {:error, reason} -> fail(frame, to_string(reason))
    end
  end
end

defmodule Custode.MCP.AskTools.ListAsks do
  @moduledoc """
  Open questions agents have raised, oldest first: the durable answer to
  "what am I being asked?" without reading the database.

  Distinct from `list_gates`, which answers "what is BLOCKED on me?". An
  unanswered ask costs nobody anything except the answer.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:agent_id, :string, description: "restrict to one agent")
  end

  @impl true
  def execute(params, frame) do
    asks =
      Custode.Asks.open()
      |> filter_agent(params[:agent_id])
      |> Enum.map(
        &%{
          id: &1.id,
          agent_id: &1.agent_id,
          question: &1.question,
          detail: &1.detail,
          asked_at: &1.inserted_at
        }
      )

    reply(frame, %{asks: asks})
  end

  defp filter_agent(asks, nil), do: asks
  defp filter_agent(asks, agent_id), do: Enum.filter(asks, &(&1.agent_id == agent_id))
end

defmodule Custode.MCP.AskTools.AnswerAsk do
  @moduledoc """
  Answer an open question. Closes the ask and delivers the answer to the
  agent as an inbox note, which its next sweep reads.

  Operator-only, and for the same reason approvals are: agents operate the
  machine, humans judge the work. An agent answering another agent's question
  to the operator would be answering on the operator's behalf.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  schema do
    field(:ask_id, :integer, required: true, description: "the ask (see: list_asks)")
    field(:answer, :string, required: true, description: "the answer, in the operator's words")
  end

  @impl true
  def execute(params, frame) do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} ->
        do_answer(params, frame)

      %{id: caller_id} ->
        fail(
          frame,
          "identity: #{caller_id} may not answer the operator's questions -- " <>
            "agents operate the machine; humans judge the work"
        )
    end
  end

  defp do_answer(params, frame) do
    case Custode.Asks.answer(params.ask_id, params.answer) do
      {:ok, ask} ->
        reply(frame, %{ask_id: ask.id, agent_id: ask.agent_id, status: ask.status})

      {:error, reason} ->
        fail(frame, to_string(reason))
    end
  end
end
