defmodule Custode.Asks do
  @moduledoc """
  Open questions from agents to the operator (#299): the NON-blocking half of
  the two ways an agent can want a human.

  ## Why this is not a gate

  `Custode.Gates` records a blocking hold. The agent sits in
  `:awaiting_permission` or `:waiting_for_user` and `ObanClaude.Agent.Tick`
  skips every beat until the operator decides, which is correct when nothing
  should proceed without a decision.

  It is wrong for a question. Observed on the live fleet on 2026-07-25:
  `adrs` asked whether an uncommitted diff was the operator's work and then
  sat idle for 1h07m, with a whole backlog it could have kept draining. The
  question blocked nothing except the agent that was polite enough to ask it.

  So: a gate is *nothing proceeds without you*. An ask is *I would like your
  opinion, and I am carrying on*. The turn that files an ask finishes
  normally, the agent returns to idle, and its next beat runs.

  ## The shape of the loop

      agent calls ask_operator      -> a row, status "open", turn completes
      operator answers              -> status "answered", plus an inbox note
      the agent's next sweep        -> reads the note with its own Read tool

  The return channel is the inbox note, exactly as `Custode.Gates.requeue!/1`
  already does for restart notices. There is no resume and no state to
  restore, because nothing was suspended.

  ## What this is not

  Not a conversation. An ask has one question and one answer, and a follow-up
  is a new ask. Threading a dialogue through a scheduled agent that may not
  run for half an hour is a different feature with a different cost, and the
  cheap version has to prove itself first.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Repo

  defmodule Ask do
    @moduledoc false
    use Ecto.Schema

    @type t :: %__MODULE__{}

    schema "asks" do
      field(:agent_id, :string)
      field(:question, :string)
      field(:detail, :string)
      field(:answer, :string)
      field(:status, :string, default: "open")
      field(:answered_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end
  end

  @doc """
  File a question from `agent_id`. Returns the stored `%Ask{}`.

  Deliberately unguarded against duplicates: an agent that asks the same
  thing twice has told you something (see the aging discussion in #299), and
  silently swallowing the second one would hide it.
  """
  @spec ask(String.t(), String.t(), keyword()) :: {:ok, Ask.t()} | {:error, term()}
  def ask(agent_id, question, opts \\ []) do
    question = String.trim(to_string(question))

    if question == "" do
      {:error, "a question needs text"}
    else
      {:ok,
       Repo.insert!(%Ask{
         agent_id: agent_id,
         question: question,
         detail: opts[:detail]
       })}
    end
  end

  @doc "Every open ask, oldest first -- the order the operator should meet them in."
  @spec open() :: [Ask.t()]
  def open do
    Repo.all(from(a in Ask, where: a.status == "open", order_by: [asc: a.inserted_at]))
  end

  @doc """
  Open asks grouped by agent id, newest-first within each agent.

  One query for the whole fleet, so resolving attention for every agent does
  not issue one per tile. Unbounded on purpose, matching
  `Custode.Gates.open_by_agent/0`: a limit here would silently drop agents
  from the needs-you group.
  """
  @spec open_by_agent() :: %{String.t() => [Ask.t()]}
  def open_by_agent do
    from(a in Ask, where: a.status == "open", order_by: [desc: a.inserted_at])
    |> Repo.all()
    |> Enum.group_by(& &1.agent_id)
  end

  @doc "The ask with this id, or nil."
  @spec get(integer() | String.t()) :: Ask.t() | nil
  def get(id), do: Repo.get(Ask, id)

  @doc """
  Answer an open ask: close the row and deliver the answer to the agent as an
  inbox note, so its next sweep reads it with its own Read tool.

  The note is best-effort. An agent with no configured routine (a sub-agent,
  a one-shot) still gets its ask closed -- losing the answer's delivery is
  better than refusing to let the operator clear the question.
  """
  @spec answer(integer() | String.t(), String.t()) :: {:ok, Ask.t()} | {:error, term()}
  def answer(id, text) do
    text = String.trim(to_string(text))

    case get(id) do
      nil ->
        {:error, "no ask #{id}"}

      %Ask{status: status} when status != "open" ->
        {:error, "ask #{id} is already #{status}"}

      %Ask{} = ask when text == "" ->
        {:error, "an answer to #{ask.id} needs text"}

      %Ask{} = ask ->
        answered =
          ask
          |> Ecto.Changeset.change(
            answer: text,
            status: "answered",
            answered_at: DateTime.utc_now()
          )
          |> Repo.update!()

        deliver(answered)
        {:ok, answered}
    end
  end

  # The agent-native return channel: a file its Read tool picks up, the same
  # mechanism Gates.requeue!/1 uses for restart notices. Inbox.drop/3 also
  # schedules the debounced beat where the routine opts into one, so an
  # answered question reaches the agent shortly rather than at the next cron.
  defp deliver(%Ask{} = ask) do
    Custode.Inbox.drop(ask.agent_id, "answer-#{ask.id}.md", """
    ANSWER to the question you asked #{relative(ask.inserted_at, ask.answered_at)}:

    > #{ask.question}

    #{ask.answer}

    The question is closed. Act on this if it changes what you were doing,
    and journal that you read it either way.
    """)

    :ok
  rescue
    # A sub-agent or one-shot has no routine and therefore no inbox. Losing
    # the delivery is better than refusing to let the operator close the
    # question, so this never propagates.
    _exception -> :ok
  end

  defp relative(%DateTime{} = from, %DateTime{} = to) do
    case max(DateTime.diff(to, from), 0) do
      seconds when seconds < 3600 -> "#{div(seconds, 60)}m ago"
      seconds when seconds < 86_400 -> "#{div(seconds, 3600)}h ago"
      seconds -> "#{div(seconds, 86_400)}d ago"
    end
  end

  defp relative(_from, _to), do: "earlier"
end
