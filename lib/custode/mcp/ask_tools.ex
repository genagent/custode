defmodule Custode.MCP.AskTools do
  @moduledoc """
  The ask surface (#299): one agent-callable tool for filing a non-blocking
  question, and operator-side tools for reading, answering and dismissing them.

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

  @question "the question, in one or two sentences the operator can answer without context"

  schema do
    field(:question, :string, description: @question)

    field(:detail, :string,
      description: "what you were doing when it came up, for the operator's context"
    )

    field(:replies, {:list, :string},
      description:
        "optional: up to 3 short answers you would accept, each a complete reply the operator " <>
          ~s|can send with one click (e.g. "Yes, take it over", "No, leave it to me"). | <>
          "Max 120 characters each. Offer them when the likely answers are predictable."
    )

    field(:agent_id, :string,
      description: "whose question (defaults to the caller; a routine may only file its own)"
    )

    field(:routine_id, :string, description: alias_for("agent_id"))
  end

  # `question` is enforced here and not by the schema (#483): a schema miss is
  # a protocol error the calling model never reads, and `params.question` on a
  # direct call without it raised KeyError.
  @impl true
  def execute(params, frame) do
    with {:ok, agent_id} <- fetch_self(params, frame),
         :ok <- check_self(frame, agent_id),
         {:ok, question} <- need(params, :question, @question),
         {:ok, ask} <-
           Custode.Asks.ask(agent_id, question,
             detail: params[:detail],
             replies: params[:replies]
           ) do
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

defmodule Custode.MCP.AskTools.DismissAsk do
  @moduledoc """
  Dismiss an open question without sending the agent an answer or an inbox
  note. An optional reason records why the question no longer needs a reply.

  Operator-only: an agent may not close a question owed to the operator.
  """
  use Anubis.Server.Component, type: :tool

  import Custode.MCP.Tools

  alias Custode.Operator.Actions

  schema do
    field(:ask_id, :integer, required: true, description: "the ask (see: list_asks)")
    field(:reason, :string, description: "optional reason the question no longer needs a reply")
  end

  @impl true
  def execute(params, frame) do
    case Custode.MCP.caller(frame) do
      %{kind: :operator} ->
        do_dismiss(params, frame)

      %{id: caller_id} ->
        fail(frame, "identity: #{caller_id} may not dismiss the operator's questions")
    end
  end

  defp do_dismiss(params, frame) do
    case Actions.dismiss_ask(params.ask_id, params[:reason]) do
      :ok ->
        ask = Custode.Asks.get(params.ask_id)
        reply(frame, %{ask_id: ask.id, agent_id: ask.agent_id, status: ask.status})

      {:error, reason} ->
        fail(frame, to_string(reason))
    end
  end
end
