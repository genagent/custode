defmodule Custode.Operator.Actions do
  @moduledoc """
  The things the operator can do to an agent, one function each (design/010
  decision 4: surfaces stay thin).

  A LiveView `handle_event` calls one of these and contains no business logic
  of its own. The fleet tile, the agent page and the inbox each grew their own
  copy of "approve", "reject" and "prompt", and the copies drifted: only the
  caretaker could be prompted from the fleet page, the agent page hid its
  composer for a paused agent although `mix custode prompt` worked, and every
  dashboard reject sent a placeholder reason (#438). One module that every
  surface calls cannot drift from itself, and when MCP parity is wanted it is
  a thin layer over the same functions.

  `run/3` takes the op atoms `Custode.Attention` puts in a signal's
  `resolving` list, so a surface can render a signal's own buttons and hand
  the click straight back without a lookup table of its own.

  Every function takes `opts` with `:via` (the surface: `:liveview`, `:cli`,
  `:mcp`) and `:by` (defaults to the operator), which land on the gate row
  (#448) and the operation log.
  """

  alias Custode.Operations.Fleet.PauseAgent
  alias ObanClaude.Agent

  @type result :: :ok | {:error, term()}

  @doc """
  Say something to an agent, in whatever state it is in. There is no state in
  which the operator should be unable to speak, and none in which a message
  should vanish:

    * idle, running, or gated: the engine takes it (it queues behind a running
      turn, and is the answer for an agent parked on a question)
    * OFFLINE: the engine has no process to cast to and answers
      `:agent_not_running`. A routine is started with the message as its
      turn's prompt, which is what a beat does with the sweep prompt
    * PAUSED: the engine DROPS a prompt cast at a paused agent (lockdown has
      no caller to refuse). The agent is resumed first, so the surface must
      say that sending will resume it

  The agent page used to hide its composer for the last two. Hiding the box
  was honest about the engine and unhelpful to the operator.
  """
  @spec message(String.t(), String.t(), keyword()) :: result()
  def message(agent_id, text, opts \\ []) do
    case String.trim(to_string(text)) do
      "" -> {:error, :empty}
      text -> deliver(agent_id, text, state_of(agent_id), opts)
    end
  end

  defp deliver(agent_id, text, :offline, _opts) do
    case Custode.Routine.get(agent_id) do
      nil ->
        {:error, :agent_not_running}

      routine ->
        args = Map.put(Custode.Routine.tick_args(routine), "prompt", text)
        {:ok, _job} = Oban.insert(Agent.Tick.new(args, queue: :ticks))
        Custode.Feed.record_prompted(agent_id, text)
        :ok
    end
  end

  defp deliver(agent_id, text, :paused, opts) do
    with :ok <- resume(agent_id, opts), do: cast(agent_id, text)
  end

  defp deliver(agent_id, text, _state, _opts), do: cast(agent_id, text)

  defp cast(agent_id, text) do
    case Agent.cast_prompt(agent_id, text) do
      :ok ->
        Custode.Feed.record_prompted(agent_id, text)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `status/1` always answers `{:ok, status}`; an agent with no process is
  # `{:ok, :offline}`, which is the case `deliver/4` branches on.
  defp state_of(agent_id) do
    {:ok, status} = Agent.status(agent_id)
    Custode.state_of(status)
  end

  @doc "Approve an agent's pending action."
  @spec approve(String.t(), String.t(), keyword()) :: result()
  def approve(agent_id, action_id, opts \\ []) do
    case Custode.approve_action(agent_id, action_id, opts) do
      :processing -> :ok
      other -> {:error, other}
    end
  end

  @doc """
  Reject an agent's pending action. `reason` is what the agent is taught;
  `standing: false` in `opts` marks it a one-off (#438).
  """
  @spec reject(String.t(), String.t(), String.t() | nil, keyword()) :: result()
  def reject(agent_id, action_id, reason, opts \\ []) do
    case Custode.reject_with_note(agent_id, action_id, reason, opts) do
      :rejected -> :ok
      other -> {:error, other}
    end
  end

  @doc "Answer a non-blocking question (#306)."
  @spec answer_ask(integer() | String.t(), String.t(), keyword()) :: result()
  def answer_ask(ask_id, text, _opts \\ []) do
    case Custode.Asks.answer(ask_id, text) do
      {:ok, _ask} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Answer an agent parked in `waiting_for_user`. The answer is a message."
  @spec answer(String.t(), String.t(), keyword()) :: result()
  def answer(agent_id, text, opts \\ []), do: message(agent_id, text, opts)

  @doc "Start a sweep now instead of at the next cron match."
  @spec beat(String.t(), keyword()) :: result()
  def beat(agent_id, _opts \\ []) do
    {:ok, _job_id} = Custode.beat(agent_id)
    :ok
  end

  @doc "Pause one agent, through the operation spine so it is logged (#382)."
  @spec pause(String.t(), keyword()) :: result()
  def pause(agent_id, opts \\ []) do
    key = Keyword.get_lazy(opts, :idempotency_key, &Ecto.UUID.generate/0)

    case PauseAgent.dispatch(agent_id,
           actor: %{kind: :operator, id: opts |> Keyword.get(:by, "operator") |> to_string()},
           transport: Keyword.get(opts, :via, :liveview),
           idempotency_key: key,
           correlation_id: key
         ) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Resume a paused agent."
  @spec resume(String.t(), keyword()) :: result()
  def resume(agent_id, _opts \\ []) do
    case Agent.resume_agent(agent_id) do
      {:error, reason} -> {:error, reason}
      _resumed -> :ok
    end
  end

  @doc """
  Run a signal's `resolving` op. `params` carries what the op needs beyond its
  own `args`: `"text"` for an answer, `"reason"` and `"one_off"` for a reject.

  Returns `{:error, {:unhandled_op, op}}` for an op no surface can carry out
  here (`:open_agent` is navigation, `:set_rail` is an edit form), so a caller
  can fall back to a link and never draws a button that does nothing (#449).
  """
  @spec run(atom(), map(), map(), keyword()) :: result()
  def run(op, args, params \\ %{}, opts \\ [])

  def run(:approve, %{agent: agent, action: action}, _params, opts),
    do: approve(agent, action, opts)

  def run(:reject, %{agent: agent, action: action}, params, opts) do
    standing? = params["one_off"] != "true"
    reject(agent, action, params["reason"], Keyword.put(opts, :standing, standing?))
  end

  def run(:answer_ask, %{ask: ask}, params, opts), do: answer_ask(ask, params["text"], opts)
  def run(:answer, %{agent: agent}, params, opts), do: answer(agent, params["text"], opts)
  def run(:beat, %{agent: agent}, _params, opts), do: beat(agent, opts)
  def run(:resume, %{agent: agent}, _params, opts), do: resume(agent, opts)
  def run(op, _args, _params, _opts), do: {:error, {:unhandled_op, op}}

  @doc "Whether `run/4` can carry out `op`, for a surface deciding button or link."
  @spec handles?(atom()) :: boolean()
  def handles?(op), do: op in [:approve, :reject, :answer_ask, :answer, :beat, :resume]
end
