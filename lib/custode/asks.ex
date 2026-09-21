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
                                       plus an `asked` feed entry (#445)
      operator answers              -> status "answered", plus an inbox note
                                       plus an `answered` feed entry
      the agent's next sweep        -> reads the note with its own Read tool

  The return channel is the inbox note, exactly as `Custode.Gates.requeue!/1`
  already does for restart notices. There is no resume and no state to
  restore, because nothing was suspended.

  ## How the operator hears about it (#445)

  Not blocking the agent must not mean not telling the human. Until #445 an
  ask was a row and nothing else, so it reached the operator only if they
  opened `/inbox` or ran `mix custode asks`: the 1h07m of invisibility that
  motivated asks had moved from the agent to the question.

  Both ends now record a feed entry, which puts the ask on the agent's tile,
  in the feed, and on ntfy through `Custode.Feed.Notify`. Neither passes
  `notify: true`. The desktop notification means "a human is needed NOW", and
  an ask, by construction, is not that: the weight of the notification says
  the same thing the non-blocking turn does.

  ## What this is not

  Not a conversation. An ask has one question and one answer, and a follow-up
  is a new ask. Threading a dialogue through a scheduled agent that may not
  run for half an hour is a different feature with a different cost, and the
  cheap version has to prove itself first.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.Feed
  alias Custode.Repo

  defmodule Ask do
    @moduledoc false
    use Ecto.Schema

    @type t :: %__MODULE__{}

    schema "asks" do
      field(:agent_id, :string)
      field(:question, :string)
      field(:detail, :string)
      # a JSON array of suggested answers; read it with `Custode.Asks.replies/1`
      field(:replies, :string)
      field(:answer, :string)
      field(:status, :string, default: "open")
      field(:answered_at, :utc_datetime_usec)
      field(:dismissal_reason, :string)
      field(:dismissed_at, :utc_datetime_usec)
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

    cond do
      question == "" ->
        {:error, "a question needs text"}

      too_many = too_many_open(agent_id) ->
        {:error, too_many}

      true ->
        file(agent_id, question, opts)
    end
  end

  # An unanswered question is not made louder by asking it again. On the live
  # fleet `redisctl` filed the same SAML question eight times in a day, once a
  # sweep, each worded a little differently, so no text comparison would have
  # caught it. The cap is the mechanical answer: past it, the agent is told
  # what it already has open, and that aging re-notifies the operator for it.
  @default_max_open 2

  defp too_many_open(agent_id) do
    max = Application.get_env(:custode, :max_open_asks, @default_max_open)

    open =
      Repo.all(
        from(a in Ask,
          where: a.agent_id == ^agent_id and a.status == "open",
          order_by: [asc: a.inserted_at]
        )
      )

    if length(open) >= max, do: too_many_message(open)
  end

  defp too_many_message(open) do
    listed = Enum.map_join(open, "; ", &~s(##{&1.id} "#{String.slice(&1.question, 0, 80)}"))

    "you already have #{length(open)} unanswered question(s): #{listed}. " <>
      "Asking again does not make one louder: the operator is re-notified as it ages. " <>
      "Work on what is not blocked, and ask only something new once one is closed."
  end

  defp file(agent_id, question, opts) do
    ask =
      Repo.insert!(%Ask{
        agent_id: agent_id,
        question: question,
        detail: opts[:detail],
        replies: encode_replies(opts[:replies])
      })

    record_asked(ask)
    {:ok, ask}
  end

  @max_replies 3
  @max_reply_chars 120

  # Suggestions are a convenience, so a malformed one is dropped and never an
  # error: it must not cost the agent its question.
  defp encode_replies(replies) when is_list(replies) do
    cleaned =
      replies
      |> Enum.filter(&is_binary/1)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.length(&1) > @max_reply_chars))
      |> Enum.uniq()
      |> Enum.take(@max_replies)

    if cleaned == [], do: nil, else: Jason.encode!(cleaned)
  end

  defp encode_replies(_none), do: nil

  @doc """
  The answers the agent suggested for `ask`, or `[]`. At most three, each one
  something the agent said it would accept (`question-inline.png`'s "or just
  say"), so a surface can offer them as one-click answers.
  """
  @spec replies(Ask.t()) :: [String.t()]
  def replies(%Ask{replies: json}) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, replies} when is_list(replies) -> Enum.filter(replies, &is_binary/1)
      _other -> []
    end
  end

  def replies(%Ask{}), do: []

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
        with {:ok, answered} <-
               close(ask,
                 answer: text,
                 status: "answered",
                 answered_at: DateTime.utc_now()
               ) do
          deliver(answered)
          record_answered(answered)
          {:ok, answered}
        end
    end
  end

  @doc """
  Dismiss an open ask without delivering an answer or waking the agent.

  The optional reason and dismissal time stay on the ask even after feed
  retention removes its audit entry. A dismissed ask is never an answer.
  """
  @spec dismiss(integer() | String.t(), String.t() | nil) ::
          {:ok, Ask.t()} | {:error, term()}
  def dismiss(id, reason \\ nil) do
    reason = reason |> to_string() |> String.trim()
    reason = if reason == "", do: nil, else: reason

    case get(id) do
      nil ->
        {:error, "no ask #{id}"}

      %Ask{status: status} when status != "open" ->
        {:error, "ask #{id} is already #{status}"}

      %Ask{} = ask ->
        with {:ok, dismissed} <-
               close(ask,
                 status: "dismissed",
                 dismissal_reason: reason,
                 dismissed_at: DateTime.utc_now()
               ) do
          record_dismissed(dismissed)
          {:ok, dismissed}
        end
    end
  end

  # Answer and dismissal compete for the same open row. Only the winning
  # transition may emit an event or deliver an inbox note.
  defp close(%Ask{} = ask, changes) do
    changes = Keyword.put(changes, :updated_at, DateTime.utc_now())
    query = from(a in Ask, where: a.id == ^ask.id and a.status == "open")

    case Repo.update_all(query, set: changes) do
      {1, _rows} ->
        {:ok, struct!(ask, changes)}

      {0, _rows} ->
        case get(ask.id) do
          nil -> {:error, "no ask #{ask.id}"}
          closed -> {:error, "ask #{ask.id} is already #{closed.status}"}
        end
    end
  end

  # The feed is how the operator hears about an ask without going looking
  # (#445). No `notify: true`: see the moduledoc for why an ask stays below
  # the desktop-notification weight. `ask_id` rides both entries so the pair
  # can be read back from the feed alone.
  defp record_asked(%Ask{} = ask) do
    Feed.record(%{
      event: "asked",
      agent: ask.agent_id,
      ask_id: ask.id,
      question: ask.question,
      summary: "asked the operator: " <> clip(ask.question)
    })
  end

  defp record_answered(%Ask{} = ask) do
    Feed.record(%{
      event: "answered",
      agent: ask.agent_id,
      ask_id: ask.id,
      question: ask.question,
      answer: ask.answer,
      summary: "operator answered ask #{ask.id}: " <> clip(ask.answer)
    })
  end

  defp record_dismissed(%Ask{} = ask) do
    summary = "operator dismissed ask #{ask.id}"

    summary =
      if ask.dismissal_reason, do: summary <> ": " <> clip(ask.dismissal_reason), else: summary

    Feed.record(%{
      event: "dismissed",
      agent: ask.agent_id,
      ask_id: ask.id,
      question: ask.question,
      reason: ask.dismissal_reason,
      summary: summary
    })
  end

  # A feed card is a line, not a transcript; the full text is on the row and
  # in the entry's own `question` / `answer` keys.
  defp clip(text), do: String.slice(text, 0, 160)

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
