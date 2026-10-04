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

  alias Custode.{AgentHandoff, Agents, Routine}
  alias Custode.Operations.Fleet.PauseAgent
  alias Custode.Operator.Authority
  alias Custode.OperatorMessages
  alias Custode.Suggestions
  alias Custode.Workflow.Launch

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

  The agent page used to hide its composer for the last two, and `mix custode
  prompt` reported success for a paused agent while the engine dropped the
  text (#472). Returns what it did, so a surface can say so.
  """
  @spec message(String.t(), String.t(), keyword()) ::
          {:ok, :queued | :delivered | :resumed | :started} | {:error, term()}
  def message(agent_id, text, opts \\ []) do
    case message_with_receipt(agent_id, text, opts) do
      {:ok, message, _disposition} -> delivery_result(message)
      {:error, {:refused, _message, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Send a message and return its durable exact-outcome receipt (#657)."
  @spec message_with_receipt(String.t(), String.t(), keyword()) ::
          {:ok, Custode.OperatorMessage.t(), :created | :duplicate}
          | {:error, {:refused, Custode.OperatorMessage.t(), term()} | term()}
  def message_with_receipt(agent_id, text, opts \\ []) do
    text
    |> to_string()
    |> String.trim()
    |> submit_message(agent_id, opts)
  end

  defp submit_message("", _agent_id, _opts), do: {:error, :empty}

  defp submit_message(text, agent_id, opts) do
    agent_id
    |> OperatorMessages.submit(text, opts, &deliver_message(agent_id, text, opts, &1))
    |> record_prompt_submission(agent_id, text)
  end

  defp record_prompt_submission({:ok, _message, :created} = result, agent_id, text) do
    :ok = Custode.Feed.record_prompted(agent_id, text)
    result
  end

  defp record_prompt_submission(result, _agent_id, _text), do: result

  defp deliver_message(agent_id, text, opts, message) do
    case Routine.get(agent_id) do
      nil -> deliver_ad_hoc(agent_id, text, opts, message)
      _routine -> deliver(agent_id, text, opts, message)
    end
  end

  # An unconfigured process has no routine replay owner. Claim its durable row
  # before waiting on the configuration boundary, then use the provider's
  # nonblocking cast so a busy process owns the queued prompt itself.
  defp deliver_ad_hoc(agent_id, text, opts, message) do
    case OperatorMessages.claim_delivery(message) do
      {:ok, claimed} ->
        result =
          AgentHandoff.admit(agent_id, fn ->
            admit_ad_hoc(agent_id, text, opts, claimed)
          end)

        settle_ad_hoc_admission(claimed, result)

      {:error, :not_queued} ->
        resolve_ad_hoc_claim_miss(message.message_id)
    end
  end

  defp admit_ad_hoc(agent_id, text, opts, claimed) do
    case Routine.get(agent_id) do
      nil ->
        with {:ok, provider} <- live_ad_hoc_provider(agent_id),
             {:ok, state} <- ad_hoc_state(agent_id, provider) do
          deliver_ad_hoc_state(agent_id, provider, text, opts, claimed, state)
        end

      _configured ->
        {:error, :agent_became_configured}
    end
  end

  defp live_ad_hoc_provider(agent_id) do
    case Agents.live_provider(agent_id) do
      {:ok, provider} -> {:ok, provider}
      :offline -> {:error, :agent_not_running}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ad_hoc_state(agent_id, provider) do
    {:ok, status} = Agents.status(agent_id, provider)
    {:ok, Custode.state_of(status)}
  end

  defp deliver_ad_hoc_state(_agent_id, _provider, _text, _opts, _claimed, :offline),
    do: {:error, :agent_not_running}

  defp deliver_ad_hoc_state(agent_id, provider, text, opts, claimed, :paused) do
    with :ok <- resume_ad_hoc(agent_id, provider, opts) do
      cast_ad_hoc(agent_id, provider, text, claimed, :resumed)
    end
  end

  defp deliver_ad_hoc_state(agent_id, provider, text, _opts, claimed, _state),
    do: cast_ad_hoc(agent_id, provider, text, claimed, :delivered)

  defp resume_ad_hoc(agent_id, provider, opts) do
    with :ok <- Authority.fleet_control(actor(opts)) do
      case Agents.resume_agent(agent_id, provider) do
        :resumed -> :ok
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected_resume_reply, other}}
      end
    end
  end

  defp cast_ad_hoc(agent_id, provider, text, claimed, how) do
    case safe_ad_hoc_cast(agent_id, provider, text, claimed.provider_correlation_id) do
      :ok ->
        record_admission(claimed, how, provider)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_ad_hoc_cast(agent_id, provider, text, correlation_id) do
    Agents.cast_prompt(agent_id, provider, text,
      origin: :operator,
      correlation_id: correlation_id
    )
  rescue
    exception -> {:error, {:cast_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:cast_throw, kind, reason}}
  end

  defp settle_ad_hoc_admission(_claimed, {:admitted, _how} = admitted), do: admitted

  defp settle_ad_hoc_admission(claimed, {:deferred, reason}),
    do: release_unadmitted(claimed, {:error, {:config_transition, reason}})

  defp settle_ad_hoc_admission(claimed, {:error, _reason} = error),
    do: release_unadmitted(claimed, error)

  defp settle_ad_hoc_admission(claimed, other),
    do: release_unadmitted(claimed, {:error, {:unexpected_admission_reply, other}})

  defp resolve_ad_hoc_claim_miss(message_id) do
    case OperatorMessages.get(message_id) do
      nil -> {:error, :message_not_found}
      %{delivery: "queued"} -> {:error, :delivery_claim_raced}
      %{delivery: "admitting"} -> {:admitted, :already_admitting}
      %{} -> {:admitted, :already_admitted}
    end
  end

  defp deliver(agent_id, text, opts, message) do
    admission_opts = [
      allow_preserved: true,
      continuation: not is_nil(message.continues_message_id),
      current_queue_head: queue_head?(message),
      durable_message: true
    ]

    Custode.AgentHandoff.admit(
      agent_id,
      fn -> admit_message(agent_id, text, opts, message) end,
      admission_opts
    )
  end

  defp admit_message(agent_id, text, opts, message) do
    case OperatorMessages.get(message.message_id) do
      %{delivery: "queued"} = queued ->
        admit_queued_message(agent_id, text, opts, message.message_id, queued)

      %{delivery: "admitting"} ->
        {:deferred, :delivery_claimed}

      %{} ->
        # A replay queued ahead of this call already admitted the row. The
        # callback executes inside the coordinator, so observing that durable
        # fact here also prevents a second provider submission.
        {:admitted, :already_admitted}

      nil ->
        {:error, :message_not_found}
    end
  end

  defp admit_queued_message(agent_id, text, opts, message_id, queued) do
    with {:ok, state} <- current_state(agent_id),
         :ok <- admission_ready(state),
         {:ok, provider} <- admission_provider(agent_id),
         {:ok, claimed} <- OperatorMessages.claim_next_delivery(queued) do
      result = deliver_ready(agent_id, text, state, opts, claimed.provider_correlation_id)
      settle_message_admission(claimed, provider, result)
    else
      {:deferred, _reason} = deferred -> deferred
      {:error, :not_next} -> {:deferred, :queued_behind_earlier_message}
      {:error, :not_queued} -> resolve_admission_claim_miss(message_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp settle_message_admission(claimed, provider, {:ok, how}),
    do: record_admission(claimed, how, provider)

  defp settle_message_admission(claimed, _provider, other),
    do: release_unadmitted(claimed, other)

  defp admission_ready(state) when state in [:running, :awaiting_permission],
    do: {:deferred, :agent_busy}

  defp admission_ready(_state), do: :ok

  defp deliver_ready(agent_id, text, :offline, _opts, correlation_id) do
    case Custode.Routine.get(agent_id) do
      nil ->
        {:error, :agent_not_running}

      routine ->
        start_and_cast(routine, text, correlation_id)
    end
  end

  defp deliver_ready(agent_id, text, :paused, opts, correlation_id) do
    with :ok <- resume(agent_id, opts), do: submit(agent_id, text, :resumed, correlation_id)
  end

  # An answer belongs to the arc that asked the question. Omitting arc_id
  # makes the wrapper keep its active arc while origin=:operator still marks
  # the response as human input.
  defp deliver_ready(agent_id, text, :waiting_for_user, _opts, correlation_id) do
    case Agents.submit_prompt(agent_id, text,
           origin: :operator,
           correlation_id: correlation_id
         ) do
      :processing ->
        {:ok, :delivered}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deliver_ready(agent_id, text, _state, _opts, correlation_id),
    do: submit(agent_id, text, :delivered, correlation_id)

  @doc false
  def replay_next(agent_id) do
    case OperatorMessages.next_queued(agent_id) do
      nil -> :empty
      message -> replay_next(agent_id, message)
    end
  end

  defp replay_next(agent_id, message) do
    with {:ok, state} <- current_state(agent_id),
         :ok <- replay_ready(state),
         {:ok, provider} <- admission_provider(agent_id),
         {:ok, claimed} <- OperatorMessages.claim_delivery(message) do
      settle_replay(claimed, provider, replay(claimed))
    else
      {:deferred, _reason} = deferred -> deferred
      {:error, :not_queued} -> resolve_replay_claim_miss(message)
      {:error, reason} -> {:error, {message.message_id, reason}}
    end
  end

  defp settle_replay(claimed, provider, {:ok, how}) do
    record_replay_delivery(claimed, how, provider)
  end

  defp settle_replay(claimed, _provider, {:error, reason}) do
    release_replay(claimed, {:error, {claimed.message_id, reason}})
  end

  defp record_replay_delivery(claimed, how, provider) do
    case OperatorMessages.record_delivery(claimed, how, provider) do
      :ok -> {:accepted, claimed.message_id}
      # The provider accepted the message. Keep it out of the replay queue
      # even if recording its exact disposition needs durable-job reconciliation.
      {:error, _reason} -> {:accepted, claimed.message_id}
    end
  end

  defp replay(%{caller_kind: "operator"} = message) do
    submit_replay(
      message.target_agent_id,
      message.prompt,
      message.provider_correlation_id
    )
  end

  defp replay(message) do
    case Agents.submit_prompt(message.target_agent_id, message.prompt,
           correlation_id: message.provider_correlation_id
         ) do
      :processing -> {:ok, :delivered}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_submit_reply, other}}
    end
  end

  defp replay_ready(state) when state in [:idle, :waiting_for_user], do: :ok
  defp replay_ready(state), do: {:deferred, state}

  defp submit_replay(agent_id, text, correlation_id) do
    with {:ok, delivered_text, prompt_opts} <- operator_delivery(agent_id, text),
         :processing <-
           Agents.submit_prompt(
             agent_id,
             delivered_text,
             Keyword.put(prompt_opts, :correlation_id, correlation_id)
           ) do
      {:ok, :delivered}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_submit_reply, other}}
    end
  end

  # `how` is what the caller is told happened (#472), so a surface can say
  # "resumed" or "started" and not only "sent".
  defp submit(agent_id, text, how, correlation_id) do
    with {:ok, delivered_text, prompt_opts} <- operator_delivery(agent_id, text),
         :processing <-
           Agents.submit_prompt(
             agent_id,
             delivered_text,
             Keyword.put(prompt_opts, :correlation_id, correlation_id)
           ) do
      {:ok, how}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_and_cast(routine, text, correlation_id) do
    with {:ok, delivered_text, prompt_opts} <-
           Custode.ConversationArcs.operator_delivery(routine, text) do
      seeds = Custode.ConversationArcs.seed_map(routine)
      config = Custode.Routine.agent_config(routine, seeds)

      case Agents.start_agent(routine.id, routine.provider, config) do
        {:ok, _pid} ->
          deliver_started(routine.id, text, delivered_text, prompt_opts, correlation_id)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp deliver_started(agent_id, _original, delivered, prompt_opts, correlation_id) do
    case Agents.submit_prompt(
           agent_id,
           delivered,
           Keyword.put(prompt_opts, :correlation_id, correlation_id)
         ) do
      :processing ->
        {:ok, :started}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp operator_delivery(agent_id, text) do
    case Custode.Routine.get(agent_id) do
      nil ->
        {:ok, text, []}

      routine ->
        Custode.ConversationArcs.operator_delivery(routine, text)
    end
  end

  defp delivery_result(%{status: "refused", error: error}), do: {:error, error}
  defp delivery_result(%{delivery: "delivered"}), do: {:ok, :delivered}
  defp delivery_result(%{delivery: "resumed"}), do: {:ok, :resumed}
  defp delivery_result(%{delivery: "started"}), do: {:ok, :started}
  defp delivery_result(%{delivery: "admitting"}), do: {:ok, :queued}
  defp delivery_result(%{delivery: "queued"}), do: {:ok, :queued}
  defp delivery_result(_message), do: {:ok, :delivered}

  defp record_admission(message, how, provider) do
    case OperatorMessages.record_delivery(message, how, provider) do
      :ok -> {:admitted, how}
      # Provider acceptance is the point of no return. Leaving the row claimed
      # lets durable-job reconciliation repair its exact disposition without
      # ever submitting the same message twice.
      {:error, _reason} -> {:admitted, how}
    end
  end

  defp release_unadmitted(message, result) do
    case OperatorMessages.release_delivery(message) do
      :ok -> result
      {:error, reason} -> {:error, {:release_delivery, reason}}
    end
  end

  defp release_replay(message, result) do
    case OperatorMessages.release_delivery(message) do
      :ok -> result
      {:error, reason} -> {:error, {message.message_id, {:release_delivery, reason}}}
    end
  end

  defp resolve_admission_claim_miss(message_id) do
    case OperatorMessages.get(message_id) do
      nil -> {:error, :message_not_found}
      %{delivery: "queued"} -> {:deferred, :delivery_claim_raced}
      %{delivery: "admitting"} -> {:deferred, :delivery_claimed}
      %{} -> {:admitted, :already_admitted}
    end
  end

  defp resolve_replay_claim_miss(message) do
    case OperatorMessages.get(message.message_id) do
      nil -> :empty
      %{delivery: "queued"} -> {:deferred, :delivery_claim_raced}
      %{delivery: "admitting"} -> {:deferred, :delivery_claimed}
      %{} -> {:accepted, message.message_id}
    end
  end

  defp admission_provider(agent_id) do
    case Agents.live_provider(agent_id) do
      {:ok, provider} ->
        {:ok, provider}

      :offline ->
        case Agents.configured_provider(agent_id) do
          provider when provider in [:claude, :codex] -> {:ok, provider}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp queue_head?(%{id: id, target_agent_id: agent_id}) do
    case OperatorMessages.next_queued(agent_id) do
      %{id: ^id} -> true
      _other -> false
    end
  end

  # `status/1` always answers `{:ok, status}`; an agent with no process is
  # `{:ok, :offline}`, which is the case `deliver/4` branches on.
  defp current_state(agent_id) do
    case Agents.status(agent_id) do
      {:ok, status} -> {:ok, Custode.state_of(status)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Approve an agent's pending action."
  @spec approve(String.t(), String.t(), keyword()) :: result()
  def approve(agent_id, action_id, opts \\ []) do
    case Custode.approve_action(agent_id, action_id, opts) do
      :processing -> :ok
      {:already_applied, :approved} -> :ok
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
      {:already_applied, :rejected} -> :ok
      other -> {:error, other}
    end
  end

  @doc "Recover a durable gate whose provider action is no longer live."
  @spec recover_gate(String.t(), String.t(), keyword()) :: result()
  def recover_gate(agent_id, action_id, _opts \\ []) do
    case Custode.Gates.recover(agent_id, action_id) do
      {:ok, :requeued} -> :ok
      {:ok, :orphaned} -> :ok
      {:ok, {:already, status, outcome}} -> {:error, {:already_decided, status, outcome}}
      {:error, reason} -> {:error, reason}
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

  @doc "Dismiss a non-blocking question without delivering anything to the agent."
  @spec dismiss_ask(integer() | String.t(), String.t() | nil) :: result()
  def dismiss_ask(ask_id, reason \\ nil) do
    case Custode.Asks.dismiss(ask_id, reason) do
      {:ok, _ask} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Answer an agent parked in `waiting_for_user`. The answer is a message."
  @spec answer(String.t(), String.t(), keyword()) :: result()
  def answer(agent_id, text, opts \\ []) do
    case message(agent_id, text, opts) do
      {:ok, _how} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Start a sweep now instead of at the next cron match."
  @spec beat(String.t(), keyword()) :: result()
  def beat(agent_id, opts \\ []) do
    case beat_with_job(agent_id, opts) do
      {:ok, _job_id} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec beat_with_job(String.t(), keyword()) :: {:ok, integer()} | {:error, term()}
  def beat_with_job(agent_id, opts \\ []) do
    # `Custode.beat/1` raises for an id with no routine. A subject is not
    # always an agent (a workflow signal, a ghost), and a surface that offers
    # the button anyway must get an error back and not a crash.
    with :ok <- Authority.fleet_control(actor(opts)),
         {:ok, _routine} <- fetch_routine(agent_id) do
      run_beat(agent_id)
    end
  end

  defp fetch_routine(agent_id) do
    case Routine.get(agent_id) do
      nil -> {:error, :no_routine}
      routine -> {:ok, routine}
    end
  end

  defp run_beat(agent_id) do
    case Custode.beat(agent_id) do
      {:deferred, reason} -> {:error, {:config_transition, reason}}
      other -> other
    end
  end

  @doc "Drop an inbox note and trigger the recipient's event kickoff."
  @spec drop_note(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def drop_note(agent_id, name, content, opts \\ []) do
    with :ok <- Authority.fleet_control(actor(opts)),
         do: Custode.Inbox.drop(agent_id, name, content)
  end

  @doc "Pause one agent, through the operation spine so it is logged (#382)."
  @spec pause(String.t(), keyword()) :: result()
  def pause(agent_id, opts \\ []) do
    key = Keyword.get_lazy(opts, :idempotency_key, &Ecto.UUID.generate/0)

    case PauseAgent.dispatch(agent_id,
           actor: actor(opts),
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
  def resume(agent_id, opts \\ []) do
    with :ok <- Authority.fleet_control(actor(opts)) do
      case Agents.resume_agent(agent_id) do
        {:error, reason} -> {:error, reason}
        _resumed -> :ok
      end
    end
  end

  @doc """
  Take a pull request out of the fleet's hands (#308): it is a human's work,
  and agents should stop treating its red checks as theirs. `agent_id` is the
  agent on whose behalf the operator is saying so.
  """
  @spec disown(String.t(), String.t(), integer() | String.t(), String.t() | nil, keyword()) ::
          result()
  def disown(agent_id, repo, number, reason, _opts \\ []) do
    with {:ok, number} <- pr_number(number),
         {:ok, _row} <- Custode.Disowned.disown(agent_id, repo, number, blank_to_nil(reason)) do
      :ok
    end
  end

  @doc "Undo a disownment: the pull request is the fleet's work again."
  @spec reclaim(String.t(), integer() | String.t(), keyword()) :: result()
  def reclaim(repo, number, _opts \\ []) do
    with {:ok, number} <- pr_number(number), do: Custode.Disowned.reclaim(repo, number)
  end

  defp pr_number(number) when is_integer(number) and number > 0, do: {:ok, number}

  defp pr_number(number) when is_binary(number) do
    case Integer.parse(String.trim_leading(String.trim(number), "#")) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, :not_a_pr_number}
    end
  end

  defp pr_number(_other), do: {:error, :not_a_pr_number}

  defp blank_to_nil(text) do
    case String.trim(to_string(text)) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  @doc """
  Drain for a restart (#132): pause the queues, let executing turns finish,
  stop the node. Confirms closed admission before returning how many turns
  it is waiting on, or an error when a queue cannot confirm its pause.
  """
  @spec drain(keyword()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def drain(opts \\ []) do
    with :ok <- Authority.human(actor(opts)) do
      case Custode.start_drain(opts[:timeout_ms], Keyword.delete(opts, :timeout_ms)) do
        count when is_integer(count) -> {:ok, count}
        {:error, _reason} = error -> error
      end
    end
  end

  @doc """
  Approve the HTML panel an agent proposed for its own page (#100). The
  operator is the authority: nothing an agent authored renders until this.
  """
  @spec approve_panel(String.t(), keyword()) :: result()
  def approve_panel(agent_id, _opts \\ []), do: Custode.Panels.approve(agent_id)

  @doc "Refuse a proposed panel. The approved one, if any, stays."
  @spec reject_panel(String.t(), keyword()) :: result()
  def reject_panel(agent_id, _opts \\ []), do: Custode.Panels.reject(agent_id)

  @doc "Restore the previously approved panel."
  @spec revert_panel(String.t(), keyword()) :: result()
  def revert_panel(agent_id, _opts \\ []), do: Custode.Panels.revert(agent_id)

  @doc """
  Drop one drafted issue from a pending batch (#215). Available while the
  batch is unfiled: a drop is a judgment until the approved continuation runs.
  """
  @spec drop_draft(integer() | String.t(), keyword()) :: result()
  def drop_draft(draft_id, opts \\ []) do
    _draft =
      Custode.Drafts.drop(to_id(draft_id), "dropped via #{Keyword.get(opts, :via, :liveview)}")

    :ok
  end

  @doc "Put a dropped draft back in its batch."
  @spec keep_draft(integer() | String.t(), keyword()) :: result()
  def keep_draft(draft_id, _opts \\ []) do
    _draft = Custode.Drafts.restore(to_id(draft_id))
    :ok
  end

  @doc "Mark one of an agent's todos done."
  @spec complete_todo(integer() | String.t(), keyword()) :: result()
  def complete_todo(todo_id, _opts \\ []) do
    _todo = Custode.Notebook.todo_complete(to_id(todo_id))
    :ok
  end

  @doc "Forget one of an agent's memories. The agent will not miss what it cannot recall."
  @spec forget_memory(String.t(), String.t(), keyword()) :: result()
  def forget_memory(agent_id, key, _opts \\ []) do
    :ok = Custode.Memory.forget(agent_id, key)
  end

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)

  @doc """
  The configured caretaker role, with the historical `:meta` tag as a
  fallback for legacy rosters. `nil` when the roster has neither.
  """
  @spec caretaker() :: String.t() | nil
  def caretaker do
    routines = Custode.Routine.all()
    caretaker = Enum.find(routines, &(&1.role == :caretaker))
    legacy = Enum.find(routines, &(:meta in &1.tags))

    case caretaker || legacy do
      nil -> nil
      routine -> routine.id
    end
  end

  @doc """
  Say something to custode itself, from anywhere (#451's entry point: most of
  what the operator wants is a sentence to the caretaker, not a visit to one
  agent). It is `message/3` to the caretaker, so it reaches it in any state.
  """
  @spec tell_custode(String.t(), keyword()) ::
          {:ok, :queued | :delivered | :resumed | :started} | {:error, term()}
  def tell_custode(text, opts \\ []) do
    case caretaker() do
      nil -> {:error, :no_caretaker}
      id -> message(id, text, opts)
    end
  end

  @doc """
  The emergency brake (#14): pause every agent that is not already paused or
  offline. Each pause goes through the operation spine under one correlation
  id, so the log shows one act and not seventeen.
  """
  @spec pause_all(keyword()) :: {:ok, [String.t()]}
  def pause_all(opts \\ []) do
    key = Keyword.get_lazy(opts, :idempotency_key, &Ecto.UUID.generate/0)

    Custode.pause_all(fn agent_id ->
      pause(agent_id, Keyword.put(opts, :idempotency_key, key))
    end)
  end

  @doc "Release the brake: resume every paused agent."
  @spec resume_all(keyword()) :: {:ok, [String.t()]}
  def resume_all(_opts \\ []), do: Custode.resume_all()

  @doc """
  Pin presence away, or hand it back to inference. `:auto` and not `:present`
  on the way back: the toggle itself counts as an operator action, so the
  reading flips to present and then lapses with the window (#328).
  """
  @spec set_presence(:present | :away | :auto, keyword()) :: :ok | {:error, String.t()}
  def set_presence(mode, opts \\ []) when mode in [:present, :away, :auto] do
    with :ok <- Authority.human(actor(opts)) do
      Custode.Presence.set(mode)
      :ok
    end
  end

  @doc "Apply a standing advisor suggestion through the roster write-back."
  @spec apply_suggestion(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def apply_suggestion(agent, field, proposed, _opts \\ []),
    do: Suggestions.apply(agent, field, proposed)

  @doc "Dismiss a standing advisor suggestion, optionally recording why."
  @spec dismiss_suggestion(String.t(), String.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()}
  def dismiss_suggestion(agent, field, proposed, reason, _opts \\ []),
    do: Suggestions.dismiss(agent, field, proposed, reason)

  @doc """
  Approve a standing workflow launch (#447). Starts the run on the rail the
  proposal quoted and returns it, so a surface can name the run it started.
  """
  @spec approve_launch(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def approve_launch(proposal_id, _opts \\ []), do: Launch.approve(proposal_id)

  @doc """
  Reject a standing workflow launch (#447). The reason rides the feed entry,
  which is also the cooldown an agent-raised proposal is checked against. A
  surface with no reason to give says where the click came from.
  """
  @spec reject_launch(String.t(), String.t() | nil, keyword()) :: result()
  def reject_launch(proposal_id, reason, opts \\ []) do
    reason =
      case String.trim(to_string(reason)) do
        "" -> "rejected via #{Keyword.get(opts, :via, :liveview)}"
        given -> given
      end

    Launch.reject(proposal_id, reason)
  end

  @doc """
  Let a run parked on its budget rail go on, with the rail raised (#447). By
  how much is `Custode.Workflow.Launch.raise_and_resume/1`'s to say.
  """
  @spec resume_run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def resume_run(run_id, _opts \\ []), do: Launch.raise_and_resume(run_id)

  @doc """
  Run a signal's `resolving` op. `params` carries what the op needs beyond its
  own `args`: `"text"` for an answer, `"reason"` and `"one_off"` for a reject.
  Dismissal carries the displayed `"ask_id"` and an optional `"reason"`: the
  id must still match the signal, so a stale click cannot dismiss the next ask.

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

  def run(:recover_gate, %{agent: agent, action: action}, _params, opts),
    do: recover_gate(agent, action, opts)

  def run(:answer_ask, %{ask: ask}, params, opts), do: answer_ask(ask, params["text"], opts)

  def run(:dismiss_ask, %{ask: ask}, params, _opts) do
    if params["ask_id"] in [ask, to_string(ask)],
      do: dismiss_ask(ask, params["reason"]),
      else: {:error, "that ask is no longer pending"}
  end

  def run(:answer, %{agent: agent}, params, opts), do: answer(agent, params["text"], opts)
  def run(:beat, %{agent: agent}, _params, opts), do: beat(agent, opts)
  def run(:resume, %{agent: agent}, _params, opts), do: resume(agent, opts)

  def run(:approve_launch, %{proposal: id}, _params, opts),
    do: id |> approve_launch(opts) |> outcome()

  def run(:reject_launch, %{proposal: id}, params, opts),
    do: reject_launch(id, params["reason"], opts)

  def run(:resume_run, %{run: id}, _params, opts), do: id |> resume_run(opts) |> outcome()
  def run(op, _args, _params, _opts), do: {:error, {:unhandled_op, op}}

  # `run/4` answers `:ok` or an error; the run a workflow op returns is for a
  # caller of the named function, which can say which run it started.
  defp outcome({:ok, _run}), do: :ok
  defp outcome({:error, reason}), do: {:error, reason}

  @doc "Whether `run/4` can carry out `op`, for a surface deciding button or link."
  @spec handles?(atom()) :: boolean()
  def handles?(op) do
    op in [
      :approve,
      :reject,
      :recover_gate,
      :answer_ask,
      :dismiss_ask,
      :answer,
      :beat,
      :resume,
      :approve_launch,
      :reject_launch,
      :resume_run
    ]
  end

  defp actor(opts) do
    Keyword.get_lazy(opts, :actor, fn ->
      %{kind: :operator, id: opts |> Keyword.get(:by, "operator") |> to_string()}
    end)
  end
end
