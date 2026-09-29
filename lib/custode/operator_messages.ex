defmodule Custode.OperatorMessages do
  @moduledoc """
  Durable, idempotent messages sent through the shared agent lifecycle.

  A public message id belongs to one caller submission. A provider correlation
  id belongs to the conversational request currently being executed. They are
  usually the same. When a human answers an agent in `waiting_for_user`, the
  answer gets its own message id while retaining the first request's provider
  correlation, so awaiting either row follows the exact resumed interaction.
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{AgentHandoff, Agents, OperatorMessage, Repo}

  @handler_id "custode-operator-messages"
  @events [
    [:oban_claude, :agent, :transition],
    [:oban_claude, :agent, :turn_completed],
    [:oban_claude, :run, :stop],
    [:oban_claude, :run, :exception],
    [:oban_codex, :agent, :transition],
    [:oban_codex, :agent, :turn_completed],
    [:oban_codex, :run, :stop],
    [:oban_codex, :run, :exception]
  ]

  @active ~w(queued executing waiting_for_input waiting_for_approval)
  @statuses ~w(queued executing waiting_for_input waiting_for_approval completed failed refused)
  @refused_delivery "refused"
  @prompt_preview_length 160
  @conversation_page_size 20
  @conversation_page_max 100

  defmodule BootReconciler do
    @moduledoc false

    @doc false
    def child_spec(_opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [[]]},
        restart: :temporary,
        type: :worker
      }
    end

    @doc false
    def start_link(_opts) do
      Custode.OperatorMessages.reconcile!()
      :ignore
    end
  end

  @doc "Attach the provider-neutral lifecycle projection."
  def attach do
    :telemetry.attach_many(@handler_id, @events, &__MODULE__.handle_event/4, nil)
  end

  @doc """
  Persist one submission and invoke `deliver` exactly once for a new
  `(caller, target, idempotency key)` tuple.

  `deliver` receives the inserted durable row and returns `{:ok, how}` or
  `{:error, reason}`. A delivery that records provider admission while holding
  the live-config boundary returns `{:admitted, how}`. Concurrent duplicates
  receive the existing row and never invoke it again. Reusing a key with
  different text is refused.
  """
  @spec submit(String.t(), String.t(), keyword(), (OperatorMessage.t() -> term())) ::
          {:ok, OperatorMessage.t(), :created | :duplicate} | {:error, term()}
  def submit(target_agent_id, prompt, opts, deliver) when is_function(deliver, 1) do
    with {:ok, caller} <- caller(opts),
         {:ok, prompt} <- prompt(prompt) do
      message_id = message_id()
      idempotency_key = Keyword.get(opts, :idempotency_key) || message_id
      prompt_hash = hash(prompt)
      continued = waiting_message(target_agent_id)
      provider_correlation_id = correlation_of(continued) || message_id

      attrs = %{
        message_id: message_id,
        caller_kind: to_string(caller.kind),
        caller_id: caller.id,
        transport: opts |> Keyword.get(:via, :internal) |> to_string(),
        target_agent_id: target_agent_id,
        idempotency_key: idempotency_key,
        prompt_hash: prompt_hash,
        prompt: prompt,
        provider_correlation_id: provider_correlation_id,
        continues_message_id: continued && continued.message_id,
        provider: target_agent_id |> configured_provider() |> to_string(),
        status: "queued",
        # The durable queue owns a message before provider admission begins.
        # A crash at any later instruction therefore leaves replayable work.
        delivery: "queued"
      }

      insert_or_get(attrs, prompt_hash, deliver)
    end
  end

  @doc "Fetch one message by its opaque public id."
  @spec get(String.t()) :: OperatorMessage.t() | nil
  def get(message_id) when is_binary(message_id) do
    Repo.one(from(m in OperatorMessage, where: m.message_id == ^message_id, limit: 1))
  end

  @doc "The lifecycle statuses accepted by operator-message reads."
  def statuses, do: @statuses

  @doc "List one caller's newest durable messages, with optional target and status filters."
  @spec list_for(%{required(:kind) => atom(), required(:id) => String.t()}, keyword()) ::
          [OperatorMessage.t()]
  def list_for(%{kind: kind, id: id}, opts \\ [])
      when is_atom(kind) and is_binary(id) and id != "" do
    limit = opts |> Keyword.get(:limit, 20) |> min(100)

    query =
      from(m in OperatorMessage,
        where: m.caller_kind == ^to_string(kind) and m.caller_id == ^id,
        order_by: [desc: m.id]
      )
      |> scope_target(opts[:agent_id])
      |> scope_status(opts[:status])

    Repo.all(from(m in query, limit: ^limit))
  end

  @doc """
  Read one bounded page of direct operator exchanges with an agent.

  Exchanges are grouped by provider correlation so an answer that continues
  a question remains with the request that opened it. Pages select complete
  exchanges, newest first, then return them oldest first for transcript
  rendering. Pass the returned `before` cursor to read the preceding page.
  The opaque cursor fixes a row high-water mark so continuations arriving
  during pagination cannot move an unread exchange across its boundary.

  This projection deliberately includes prompt and result text and is for
  trusted local operator surfaces. MCP reads keep using the authority-filtered
  public shapes above.
  """
  @spec conversation(String.t(), keyword()) ::
          {:ok,
           %{
             exchanges: [map()],
             before: String.t() | nil,
             has_older: boolean()
           }}
          | {:error, {:invalid_cursor, term()}}
  def conversation(target_agent_id, opts \\ []) when is_binary(target_agent_id) do
    limit = conversation_limit(opts[:limit])

    with {:ok, cursor} <- decode_conversation_cursor(opts[:before], target_agent_id) do
      snapshot_id = cursor_snapshot_id(cursor, target_agent_id)

      groups_query =
        from(m in OperatorMessage,
          where:
            m.target_agent_id == ^target_agent_id and m.caller_kind == "operator" and
              m.id <= ^snapshot_id,
          group_by: m.provider_correlation_id,
          order_by: [desc: max(m.id)],
          select: %{
            correlation_id: m.provider_correlation_id,
            first_id: min(m.id),
            last_id: max(m.id)
          }
        )
        |> before_exchange(cursor)

      groups = Repo.all(from(g in groups_query, limit: ^(limit + 1)))
      has_older = length(groups) > limit
      selected = Enum.take(groups, limit)
      correlation_ids = Enum.map(selected, & &1.correlation_id)

      rows = conversation_rows(target_agent_id, correlation_ids, snapshot_id)
      rows_by_correlation = Enum.group_by(rows, & &1.provider_correlation_id)

      exchanges =
        selected
        |> Enum.reverse()
        |> Enum.map(fn group ->
          conversation_exchange(group, Map.fetch!(rows_by_correlation, group.correlation_id))
        end)

      {:ok,
       %{
         exchanges: exchanges,
         before:
           if(has_older,
             do: conversation_cursor(List.last(selected), target_agent_id, snapshot_id),
             else: nil
           ),
         has_older: has_older
       }}
    end
  end

  @doc "Whether this authenticated caller may inspect the message."
  def visible_to?(_message, %{kind: :operator}), do: true

  def visible_to?(%OperatorMessage{} = message, %{kind: kind, id: id}) do
    message.caller_kind == to_string(kind) and message.caller_id == id
  end

  def visible_to?(_message, _caller), do: false

  @doc "Wait for one exact message to settle, or return its current durable state on timeout."
  @spec await(String.t(), non_neg_integer()) ::
          {:ok, OperatorMessage.t(), timed_out :: boolean()} | {:error, :not_found}
  def await(message_id, timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0 do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    poll(message_id, deadline)
  end

  @doc "The stable MCP-facing shape. Prompt text and idempotency keys are omitted."
  def public(%OperatorMessage{} = message) do
    %{
      message_id: message.message_id,
      target_agent_id: message.target_agent_id,
      caller: %{
        kind: message.caller_kind,
        id: message.caller_id,
        transport: message.transport
      },
      status: message.status,
      delivery: message.delivery,
      provider: message.provider,
      provider_turn: %{
        generation: message.agent_generation,
        turn_id: message.agent_turn_id,
        arc_id: message.arc_id,
        session_id: message.provider_session_id
      },
      continues_message_id: message.continues_message_id,
      detail: message.detail,
      result: message.result,
      error: message.error,
      inserted_at: iso8601(message.inserted_at),
      started_at: iso8601(message.started_at),
      completed_at: iso8601(message.completed_at)
    }
  end

  @doc "A bounded discovery shape; exact results stay on `await_agent`."
  def public_summary(%OperatorMessage{} = message) do
    %{
      message_id: message.message_id,
      agent_id: message.target_agent_id,
      status: message.status,
      delivery: message.delivery,
      provider: message.provider,
      continues_message_id: message.continues_message_id,
      prompt_preview: String.slice(message.prompt, 0, @prompt_preview_length),
      inserted_at: iso8601(message.inserted_at),
      started_at: iso8601(message.started_at),
      completed_at: iso8601(message.completed_at)
    }
  end

  @doc "Queued messages for one target, in caller submission order."
  def queued_for(target_agent_id) when is_binary(target_agent_id) do
    Repo.all(
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^target_agent_id and m.status == "queued" and
            m.delivery == "queued",
        order_by: [asc: m.id]
      )
    )
  end

  @doc "Atomically claim a queued message for one provider-admission attempt."
  @spec claim_delivery(OperatorMessage.t()) ::
          {:ok, OperatorMessage.t()} | {:error, :not_queued}
  def claim_delivery(%OperatorMessage{} = message), do: claim_delivery(message, :any)

  @doc "Atomically claim a queued message only when it is the target's oldest queued row."
  @spec claim_next_delivery(OperatorMessage.t()) ::
          {:ok, OperatorMessage.t()} | {:error, :not_queued | :not_next}
  def claim_next_delivery(%OperatorMessage{} = message), do: claim_delivery(message, :next)

  defp claim_delivery(
         %OperatorMessage{id: id, provider_correlation_id: correlation_id},
         order
       )
       when order in [:any, :next] do
    token = Ecto.UUID.generate()

    Repo.transaction(
      fn -> claim_delivery!(id, correlation_id, token, order) end,
      mode: :immediate
    )
    |> claim_result()
  end

  defp claim_delivery!(id, correlation_id, token, order) do
    message = id |> claimable_message() |> ensure_queued!()
    ensure_next!(message, id, order)
    persist_delivery_claim!(id, correlation_id, token)
  end

  defp claimable_message(id) do
    Repo.one(
      from(m in OperatorMessage,
        where: m.id == ^id,
        select: %{
          status: m.status,
          delivery: m.delivery,
          target_agent_id: m.target_agent_id
        }
      )
    )
  end

  defp ensure_queued!(%{status: "queued", delivery: "queued"} = message), do: message
  defp ensure_queued!(_message), do: Repo.rollback(:not_queued)

  defp ensure_next!(_message, _id, :any), do: :ok

  defp ensure_next!(message, id, :next) do
    if oldest_queued_id(message.target_agent_id) == id,
      do: :ok,
      else: Repo.rollback(:not_next)
  end

  defp oldest_queued_id(target_agent_id) do
    Repo.one(
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^target_agent_id and m.status == "queued" and
            m.delivery == "queued",
        order_by: [asc: m.id],
        select: m.id,
        limit: 1
      )
    )
  end

  defp persist_delivery_claim!(id, correlation_id, token) do
    # Provider jobs use a monotonic durable id. Snapshotting it under the same
    # immediate write lock as the claim distinguishes an old shared-correlation
    # job from the job this attempt may enqueue, even at equal timestamps.
    claim_after_job_id = latest_job_id(correlation_id) || 0
    claimed_at = now()

    {updated_count, _rows} =
      Repo.update_all(
        from(m in OperatorMessage,
          where: m.id == ^id and m.status == "queued" and m.delivery == "queued"
        ),
        set: [
          delivery: "admitting",
          claim_token: token,
          claimed_at: claimed_at,
          claim_after_job_id: claim_after_job_id,
          updated_at: claimed_at
        ]
      )

    claimed_message!(updated_count, id)
  end

  defp claimed_message!(1, id), do: Repo.get!(OperatorMessage, id)
  defp claimed_message!(0, _id), do: Repo.rollback(:not_queued)

  defp claim_result({:ok, claimed}), do: {:ok, claimed}
  defp claim_result({:error, :not_queued}), do: {:error, :not_queued}
  defp claim_result({:error, :not_next}), do: {:error, :not_next}

  @doc "Release an unadmitted claim so the durable message can be replayed."
  @spec release_delivery(OperatorMessage.t()) :: :ok | {:error, :not_admitting}
  def release_delivery(%OperatorMessage{id: id, claim_token: token})
      when is_binary(token) and token != "" do
    {updated_count, _rows} =
      Repo.update_all(
        from(m in OperatorMessage,
          where:
            m.id == ^id and m.status == "queued" and m.delivery == "admitting" and
              m.claim_token == ^token
        ),
        set: [
          delivery: "queued",
          claim_token: nil,
          claimed_at: nil,
          claim_after_job_id: nil,
          updated_at: now()
        ]
      )

    case updated_count do
      1 -> :ok
      0 -> {:error, :not_admitting}
    end
  end

  def release_delivery(%OperatorMessage{}), do: {:error, :not_admitting}

  @doc "Record that a claimed message was handed to its live provider."
  @spec record_delivery(OperatorMessage.t(), term(), atom() | String.t()) ::
          :ok | {:error, :not_admitting}
  def record_delivery(%OperatorMessage{id: id, claim_token: token}, how, provider)
      when is_binary(token) and token != "" do
    now = now()

    {updated_count, _rows} =
      Repo.update_all(
        from(m in OperatorMessage,
          # Fast test providers, and occasionally a very short real turn, can
          # publish their completion telemetry before submit_prompt/3 returns.
          # Admission still happened and its exact disposition must win over
          # the temporary claim without rewriting lifecycle status that
          # telemetry already made terminal.
          where: m.id == ^id and m.delivery == "admitting" and m.claim_token == ^token
        ),
        set: [
          delivery: to_string(how),
          claim_token: nil,
          claimed_at: nil,
          claim_after_job_id: nil,
          provider: to_string(provider),
          detail: nil,
          updated_at: now
        ]
      )

    case updated_count do
      1 -> :ok
      0 -> {:error, :not_admitting}
    end
  end

  def record_delivery(%OperatorMessage{}, _how, _provider), do: {:error, :not_admitting}

  @doc "Return the oldest durable message waiting for provider admission."
  def next_queued(target_agent_id) when is_binary(target_agent_id) do
    Repo.one(
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^target_agent_id and m.status == "queued" and
            m.delivery == "queued",
        order_by: [asc: m.id],
        limit: 1
      )
    )
  end

  @doc "Reclaim prompts accepted only into a provider process's volatile queue."
  def defer_unstarted(target_agent_id) when is_binary(target_agent_id) do
    rows =
      Repo.all(
        from(m in OperatorMessage,
          where: m.target_agent_id == ^target_agent_id and m.status == "queued",
          order_by: [asc: m.id]
        )
      )

    changed? =
      Enum.reduce(rows, false, fn row, changed? ->
        case latest_job(row.provider_correlation_id) do
          nil ->
            update!(row, %{
              delivery: "queued",
              claim_token: nil,
              claimed_at: nil,
              claim_after_job_id: nil,
              detail: "waiting for provider admission after live configuration changed"
            })

            true

          _job ->
            reconcile_correlation(row.provider_correlation_id)
            changed?
        end
      end)

    if changed?, do: Custode.PubSubBridge.broadcast({:operator_message_changed, target_agent_id})

    :ok
  end

  @doc "Recover active rows from durable Oban metadata after an application restart."
  def reconcile! do
    correlations =
      Repo.all(
        from(m in OperatorMessage,
          where: m.status in ["queued", "executing"] or m.delivery == "admitting",
          distinct: true,
          select: m.provider_correlation_id
        )
      )

    Enum.each(correlations, &reconcile_correlation/1)
    :ok
  end

  @doc "Routine ids that still own non-terminal operator messages."
  @spec active_target_ids() :: [String.t()]
  def active_target_ids do
    Repo.all(
      from(m in OperatorMessage,
        where: m.status in ^@active,
        distinct: true,
        select: m.target_agent_id
      )
    )
  end

  @doc "Settle work that can no longer be delivered because its routine was removed."
  @spec settle_removed(String.t()) :: :ok
  def settle_removed(target_agent_id) when is_binary(target_agent_id) do
    now = now()

    {updated, _rows} =
      Repo.update_all(
        from(m in OperatorMessage,
          where: m.target_agent_id == ^target_agent_id and m.status in ^@active
        ),
        set: [
          status: "refused",
          delivery: @refused_delivery,
          claim_token: nil,
          claimed_at: nil,
          claim_after_job_id: nil,
          detail: "routine removed before provider delivery",
          error: error_map(:delivery_refused, :routine_removed),
          completed_at: now,
          updated_at: now
        ]
      )

    broadcast_message_changes(updated, [target_agent_id])

    :ok
  end

  @doc "Settle the durable exchange when the operator rejects its approval request."
  @spec reject_approval(String.t(), String.t() | nil) :: :ok
  def reject_approval(target_agent_id, reason) when is_binary(target_agent_id) do
    waiting =
      Repo.one(
        from(m in OperatorMessage,
          where: m.target_agent_id == ^target_agent_id and m.status == "waiting_for_approval",
          order_by: [desc: m.id],
          limit: 1
        )
      )

    if waiting do
      update_statuses(waiting.provider_correlation_id, ["waiting_for_approval"], %{
        status: "refused",
        error: %{
          "kind" => "operator_rejected",
          "detail" => reason || "no reason given"
        },
        completed_at: now()
      })
    end

    :ok
  end

  @doc false
  def handle_event(event, measurements, meta, config) do
    do_handle_event(event, measurements, meta, config)
  rescue
    exception ->
      require Logger

      Logger.error(
        "Custode.OperatorMessages handler error (kept attached): " <>
          Exception.message(exception)
      )

      :ok
  end

  defp insert_or_get(attrs, prompt_hash, deliver) do
    changeset = OperatorMessage.create_changeset(attrs)

    case Repo.insert(changeset,
           on_conflict: :nothing,
           conflict_target: [:caller_kind, :caller_id, :target_agent_id, :idempotency_key],
           returning: true
         ) do
      {:ok, %OperatorMessage{id: nil}} ->
        duplicate(attrs, prompt_hash)

      {:ok, %OperatorMessage{} = message} ->
        deliver_new(message, deliver)

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp scope_target(query, nil), do: query

  defp scope_target(query, agent_id),
    do: from(m in query, where: m.target_agent_id == ^agent_id)

  defp scope_status(query, nil), do: query
  defp scope_status(query, status), do: from(m in query, where: m.status == ^status)

  defp conversation_limit(nil), do: @conversation_page_size

  defp conversation_limit(limit) when is_integer(limit),
    do: limit |> max(1) |> min(@conversation_page_max)

  defp conversation_limit(_other), do: @conversation_page_size

  defp conversation_rows(_target_agent_id, [], _snapshot_id), do: []

  defp conversation_rows(target_agent_id, correlation_ids, snapshot_id) do
    Repo.all(
      from(m in OperatorMessage,
        where:
          m.target_agent_id == ^target_agent_id and m.caller_kind == "operator" and
            m.provider_correlation_id in ^correlation_ids and m.id <= ^snapshot_id,
        order_by: [asc: m.id]
      )
    )
  end

  defp before_exchange(query, %{last_id: last_id}),
    do: from(m in query, having: max(m.id) < ^last_id)

  defp before_exchange(query, _before), do: query

  defp cursor_snapshot_id(%{snapshot_id: snapshot_id}, _target_agent_id), do: snapshot_id

  defp cursor_snapshot_id(nil, target_agent_id) do
    Repo.one(
      from(m in OperatorMessage,
        where: m.target_agent_id == ^target_agent_id and m.caller_kind == "operator",
        select: max(m.id)
      )
    ) || 0
  end

  defp conversation_cursor(nil, _target_agent_id, _snapshot_id), do: nil

  defp conversation_cursor(%{last_id: last_id}, target_agent_id, snapshot_id) do
    %{
      "resource" => "operator_conversation",
      "scope" => target_agent_id,
      "last_id" => last_id,
      "snapshot_id" => snapshot_id
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_conversation_cursor(nil, _target_agent_id), do: {:ok, nil}

  defp decode_conversation_cursor(cursor, target_agent_id) when is_binary(cursor) do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{
            "resource" => "operator_conversation",
            "scope" => ^target_agent_id,
            "last_id" => last_id,
            "snapshot_id" => snapshot_id
          }} <- Jason.decode(encoded),
         true <-
           is_integer(last_id) and last_id > 0 and is_integer(snapshot_id) and
             snapshot_id >= last_id do
      {:ok, %{last_id: last_id, snapshot_id: snapshot_id}}
    else
      _invalid -> {:error, {:invalid_cursor, cursor}}
    end
  end

  defp decode_conversation_cursor(cursor, _target_agent_id),
    do: {:error, {:invalid_cursor, cursor}}

  defp conversation_exchange(group, rows) do
    latest = List.last(rows)

    %{
      id: group.correlation_id,
      first_id: group.first_id,
      last_id: group.last_id,
      prompts: Enum.map(rows, &conversation_prompt/1),
      status: latest.status,
      delivery: latest.delivery,
      provider: latest_value(rows, :provider),
      detail: latest_value(rows, :detail),
      answer: rows |> latest_value(:result) |> conversation_answer(),
      error: rows |> latest_value(:error) |> conversation_error(),
      result: latest_value(rows, :result),
      raw_error: latest_value(rows, :error),
      inserted_at: hd(rows).inserted_at,
      updated_at: latest.completed_at || latest.updated_at
    }
  end

  defp conversation_prompt(message) do
    %{
      id: message.message_id,
      text: message.prompt,
      caller_id: message.caller_id,
      continued: not is_nil(message.continues_message_id),
      detail: message.detail,
      inserted_at: message.inserted_at
    }
  end

  defp latest_value(rows, field) do
    rows
    |> Enum.reverse()
    |> Enum.find_value(&Map.get(&1, field))
  end

  defp conversation_answer(%{"output" => output}), do: output_text(output)
  defp conversation_answer(_result), do: nil

  defp output_text(output) when is_binary(output), do: output

  defp output_text(%{"directive" => "ask_user", "question" => text}) when is_binary(text),
    do: text

  defp output_text(%{"directive" => "request_permission", "action" => text})
       when is_binary(text),
       do: text

  defp output_text(%{"summary" => text}) when is_binary(text), do: text

  defp output_text(output) when is_map(output) or is_list(output),
    do: Jason.encode!(output, pretty: true)

  defp output_text(output), do: inspect(output)

  defp conversation_error(%{"detail" => detail}) when is_binary(detail), do: detail
  defp conversation_error(error) when is_map(error), do: Jason.encode!(error, pretty: true)
  defp conversation_error(_error), do: nil

  defp duplicate(attrs, prompt_hash) do
    existing =
      Repo.one!(
        from(m in OperatorMessage,
          where:
            m.caller_kind == ^attrs.caller_kind and m.caller_id == ^attrs.caller_id and
              m.target_agent_id == ^attrs.target_agent_id and
              m.idempotency_key == ^attrs.idempotency_key,
          limit: 1
        )
      )

    if existing.prompt_hash == prompt_hash,
      do: {:ok, existing, :duplicate},
      else: {:error, :idempotency_conflict}
  end

  defp deliver_new(message, deliver) do
    result =
      case safe_deliver(deliver, message) do
        {:admitted, _how} ->
          {:ok, Repo.get!(OperatorMessage, message.id), :created}

        {:ok, how} ->
          updated = update!(message, %{delivery: to_string(how)})
          {:ok, updated, :created}

        {:deferred, reason} ->
          {updated_count, _rows} =
            Repo.update_all(
              from(m in OperatorMessage,
                where: m.id == ^message.id and m.delivery == "queued"
              ),
              set: [
                detail: "waiting for live configuration: #{inspect(reason)}",
                updated_at: now()
              ]
            )

          if updated_count > 0, do: AgentHandoff.work_queued(message.target_agent_id)
          updated = Repo.get!(OperatorMessage, message.id)
          {:ok, updated, :created}

        {:error, reason} ->
          updated =
            update!(message, %{
              status: "refused",
              delivery: @refused_delivery,
              error: error_map(:delivery_refused, reason),
              completed_at: now()
            })

          {:error, {:refused, updated, reason}}
      end

    Custode.PubSubBridge.broadcast({:operator_message_changed, message.target_agent_id})
    result
  end

  defp safe_deliver(deliver, message) do
    deliver.(message)
  rescue
    exception -> {:error, {:delivery_exception, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {:delivery_throw, kind, reason}}
  end

  defp do_handle_event([provider, :agent, :transition], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    case correlation(meta) do
      nil ->
        :ok

      correlation_id ->
        case meta.to do
          :running ->
            update_active(correlation_id, identity_attrs(provider, meta, "executing"))

          :waiting_for_user ->
            update_after_completion(
              correlation_id,
              identity_attrs(provider, meta, "waiting_for_input")
              |> Map.put(:detail, gated_detail(meta.agent_id, :waiting_for_user))
            )

          :awaiting_permission ->
            update_after_completion(
              correlation_id,
              identity_attrs(provider, meta, "waiting_for_approval")
              |> Map.put(:detail, gated_detail(meta.agent_id, :awaiting_permission))
            )

          _other ->
            :ok
        end
    end
  end

  defp do_handle_event([provider, :agent, :turn_completed], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    case correlation(meta) do
      nil ->
        :ok

      correlation_id ->
        attrs = completion_attrs(provider, meta)
        update_active(correlation_id, attrs)
    end
  end

  defp do_handle_event([provider, :run, :stop], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    case job_correlation(meta) do
      correlation_id when is_binary(correlation_id) ->
        attrs =
          provider
          |> run_result(meta.result)
          |> Map.merge(job_identity_attrs(provider, meta))
          |> ensure_live_owner(meta)

        update_active(correlation_id, attrs)

      _none ->
        :ok
    end
  end

  defp do_handle_event([provider, :run, :exception], _measurements, meta, _config)
       when provider in [:oban_claude, :oban_codex] do
    case job_correlation(meta) do
      correlation_id when is_binary(correlation_id) ->
        update_active(
          correlation_id,
          job_identity_attrs(provider, meta)
          |> Map.merge(%{
            status: "failed",
            error: error_map(:provider_exception, meta.error),
            completed_at: now()
          })
        )

      _none ->
        :ok
    end
  end

  defp do_handle_event(_event, _measurements, _meta, _config), do: :ok

  defp completion_attrs(provider, meta) do
    base =
      identity_attrs(provider, meta, completion_status(meta.outcome))
      |> Map.put(:provider_session_id, meta[:session_id])

    case meta.outcome do
      :completed ->
        Map.put(base, :completed_at, now())

      outcome ->
        Map.merge(base, %{error: error_map(outcome, meta[:outcome_reason]), completed_at: now()})
    end
  end

  defp completion_status(:completed), do: "completed"
  defp completion_status(_failure), do: "failed"

  defp identity_attrs(provider, meta, status) do
    %{
      status: status,
      provider: provider_name(provider),
      agent_generation: meta[:agent_generation],
      agent_turn_id: meta[:agent_turn_id],
      arc_id: meta[:arc_id]
    }
    |> active_timestamps(status)
  end

  defp job_identity_attrs(provider, meta) do
    job_meta = job_meta(meta)

    %{
      provider: provider_name(provider),
      agent_generation: job_meta["agent_generation"],
      agent_turn_id: job_meta["agent_turn_id"],
      arc_id: job_meta["arc_id"],
      provider_session_id: job_meta["session_id"]
    }
  end

  defp active_timestamps(attrs, "executing"),
    do: Map.merge(attrs, %{started_at: now(), completed_at: nil})

  defp active_timestamps(attrs, status)
       when status in ["waiting_for_input", "waiting_for_approval"],
       do: Map.put(attrs, :completed_at, nil)

  defp active_timestamps(attrs, _status), do: attrs

  defp run_result(:oban_claude, %ClaudeWrapper.Result{is_error: true} = result) do
    %{
      status: "failed",
      result: output_map(ObanClaude.structured(result) || result.result),
      error: error_map(:provider_result_error, result.result),
      completed_at: now()
    }
  end

  defp run_result(:oban_claude, %ClaudeWrapper.Result{} = result),
    do: %{result: output_map(ObanClaude.structured(result) || result.result)}

  defp run_result(:oban_codex, %CodexWrapper.Result{success: false} = result) do
    %{
      status: "failed",
      result: output_map(ObanCodex.structured(result) || ObanCodex.text(result)),
      error: error_map(:provider_result_error, result.stderr),
      completed_at: now()
    }
  end

  defp run_result(:oban_codex, %CodexWrapper.Result{} = result),
    do: %{result: output_map(ObanCodex.structured(result) || ObanCodex.text(result))}

  defp run_result(_provider, result), do: %{result: output_map(inspect(result))}

  defp reconcile_correlation(correlation_id) do
    job = latest_job(correlation_id)
    release_unowned_admitting(correlation_id, job)

    case job do
      nil ->
        preserve_queued_without_job(correlation_id)

      %Oban.Job{state: state} = job when state in ["available", "scheduled", "retryable"] ->
        provider = job_provider(job)
        recover_admitting_delivery(correlation_id, provider)

        update_active(
          correlation_id,
          Map.merge(job_attrs(job), %{
            status: "queued",
            provider: provider
          })
        )

      %Oban.Job{state: "executing"} = job ->
        provider = job_provider(job)
        recover_admitting_delivery(correlation_id, provider)

        update_active(
          correlation_id,
          Map.merge(job_attrs(job), %{
            status: "executing",
            provider: provider
          })
        )

      %Oban.Job{state: "completed"} = job ->
        recover_admitting_delivery(correlation_id, job_provider(job))

        update_active(
          correlation_id,
          job_attrs(job)
          |> Map.merge(%{
            status: "failed",
            error: error_map(:delivery_interrupted, :completed_without_lifecycle_projection),
            completed_at: job.completed_at || now()
          })
        )

      %Oban.Job{state: state} = job when state in ["cancelled", "discarded"] ->
        recover_admitting_delivery(correlation_id, job_provider(job))

        update_active(
          correlation_id,
          Map.merge(job_attrs(job), %{
            status: "failed",
            error: error_map(:recovered_job_state, state),
            completed_at: now()
          })
        )
    end
  end

  defp preserve_queued_without_job(correlation_id) do
    now = now()

    Repo.update_all(
      from(m in OperatorMessage,
        where: m.provider_correlation_id == ^correlation_id and m.status == "queued"
      ),
      set: [
        delivery: "queued",
        claim_token: nil,
        claimed_at: nil,
        claim_after_job_id: nil,
        updated_at: now
      ]
    )

    update_statuses(correlation_id, ["executing"], %{
      status: "failed",
      error: error_map(:delivery_interrupted, :no_durable_job),
      completed_at: now
    })
  end

  defp recover_admitting_delivery(correlation_id, provider) do
    Repo.update_all(
      from(m in OperatorMessage,
        where: m.provider_correlation_id == ^correlation_id and m.delivery == "admitting"
      ),
      set: [
        delivery: "delivered",
        claim_token: nil,
        claimed_at: nil,
        claim_after_job_id: nil,
        provider: provider,
        updated_at: now()
      ]
    )

    :ok
  end

  defp release_unowned_admitting(correlation_id, %Oban.Job{id: job_id})
       when is_integer(job_id) do
    # A job owns this attempt only when it was inserted after the atomic claim
    # boundary. Equality means it was already present when the claim began.
    release_admitting(
      from(m in OperatorMessage,
        where:
          m.provider_correlation_id == ^correlation_id and m.delivery == "admitting" and
            (is_nil(m.claim_after_job_id) or m.claim_after_job_id >= ^job_id)
      )
    )
  end

  defp release_unowned_admitting(correlation_id, _missing_or_undated_job) do
    release_admitting(
      from(m in OperatorMessage,
        where: m.provider_correlation_id == ^correlation_id and m.delivery == "admitting"
      )
    )
  end

  defp release_admitting(query) do
    Repo.update_all(query,
      set: [
        status: "queued",
        delivery: "queued",
        claim_token: nil,
        claimed_at: nil,
        claim_after_job_id: nil,
        agent_generation: nil,
        agent_turn_id: nil,
        arc_id: nil,
        provider_session_id: nil,
        detail: nil,
        result: nil,
        error: nil,
        started_at: nil,
        completed_at: nil,
        updated_at: now()
      ]
    )

    :ok
  end

  defp latest_job(correlation_id) do
    Repo.one(
      from(j in Oban.Job,
        where: fragment("json_extract(?, '$.correlation_id') = ?", j.meta, ^correlation_id),
        order_by: [desc: j.id],
        limit: 1
      )
    )
  end

  defp latest_job_id(correlation_id) do
    Repo.one(
      from(j in Oban.Job,
        where: fragment("json_extract(?, '$.correlation_id') = ?", j.meta, ^correlation_id),
        order_by: [desc: j.id],
        select: j.id,
        limit: 1
      )
    )
  end

  defp job_provider(%Oban.Job{worker: "ObanClaude.Agent.Job"}), do: "claude"
  defp job_provider(%Oban.Job{worker: "ObanCodex.Agent.Job"}), do: "codex"
  defp job_provider(_job), do: nil

  defp configured_provider(agent_id) do
    case Agents.configured_provider(agent_id) do
      provider when provider in [:claude, :codex] -> provider
      {:error, _reason} -> :claude
    end
  end

  defp job_attrs(%Oban.Job{meta: meta, attempted_at: attempted_at}) do
    %{
      agent_generation: meta["agent_generation"],
      agent_turn_id: meta["agent_turn_id"],
      arc_id: meta["arc_id"],
      started_at: attempted_at
    }
  end

  defp ensure_live_owner(%{status: "failed"} = attrs, _meta), do: attrs

  defp ensure_live_owner(attrs, meta) do
    if live_owner?(meta) do
      attrs
    else
      Map.merge(attrs, %{
        status: "failed",
        error: error_map(:delivery_interrupted, :provider_finished_without_live_owner),
        completed_at: now()
      })
    end
  end

  defp live_owner?(meta) do
    job_meta = job_meta(meta)

    with agent_id when is_binary(agent_id) <- job_meta["agent_id"],
         generation when is_binary(generation) <- job_meta["agent_generation"],
         turn_id when is_binary(turn_id) <- job_meta["agent_turn_id"],
         {:ok, %{continuation: continuation}} when is_map(continuation) <-
           Agents.info(agent_id) do
      continuation[:agent_generation] == generation and continuation[:agent_turn_id] == turn_id
    else
      _missing_or_stale -> false
    end
  end

  defp update_active(correlation_id, %{status: "executing"} = attrs) do
    # A continued exchange must retain the question or approval text that
    # caused the continuation. Ordinary queue/admission detail is transient
    # and is cleared when execution starts.
    statuses = ["waiting_for_input", "waiting_for_approval", "queued", "executing"]
    targets = correlation_targets(correlation_id, statuses)
    now = now()

    {:ok, updated} =
      Repo.transaction(fn ->
        cleared =
          persist_statuses(
            correlation_id,
            ["queued", "executing"],
            Map.put(attrs, :detail, nil),
            now
          )

        retained =
          persist_statuses(
            correlation_id,
            ["waiting_for_input", "waiting_for_approval"],
            attrs,
            now
          )

        retained + cleared
      end)

    broadcast_message_changes(updated, targets)
    :ok
  end

  defp update_active(correlation_id, attrs) do
    update_statuses(correlation_id, @active, attrs)
  end

  # The wrappers emit turn_completed before the state-machine transition that
  # classifies a successful structured result as a question or approval gate.
  # Let that immediately-following transition replace the provisional
  # completed state, while a failed row remains terminal.
  defp update_after_completion(correlation_id, attrs) do
    statuses = ["completed" | @active]
    targets = correlation_targets(correlation_id, statuses)
    detail = attrs[:detail]
    attrs = Map.delete(attrs, :detail)
    now = now()

    {:ok, updated} =
      Repo.transaction(fn ->
        updated = persist_statuses(correlation_id, statuses, attrs, now)

        if updated > 0 and is_binary(detail),
          do: persist_latest_detail(correlation_id, detail, now)

        updated
      end)

    broadcast_message_changes(updated, targets)
    :ok
  end

  defp update_statuses(correlation_id, statuses, attrs) do
    now = now()
    targets = correlation_targets(correlation_id, statuses)
    updated = persist_statuses(correlation_id, statuses, attrs, now)
    broadcast_message_changes(updated, targets)

    :ok
  end

  defp persist_statuses(correlation_id, statuses, attrs, now) do
    {updated, _rows} =
      Repo.update_all(
        from(m in OperatorMessage,
          where:
            m.provider_correlation_id == ^correlation_id and m.status in ^statuses and
              (is_nil(m.delivery) or m.delivery != "queued")
        ),
        set: Map.to_list(Map.put(attrs, :updated_at, now))
      )

    updated
  end

  defp persist_latest_detail(correlation_id, detail, now) do
    latest_id =
      Repo.one(
        from(m in OperatorMessage,
          where:
            m.provider_correlation_id == ^correlation_id and
              (is_nil(m.delivery) or m.delivery != "queued"),
          order_by: [desc: m.id],
          select: m.id,
          limit: 1
        )
      )

    if latest_id do
      Repo.update_all(from(m in OperatorMessage, where: m.id == ^latest_id),
        set: [detail: detail, updated_at: now]
      )
    end
  end

  defp correlation_targets(correlation_id, statuses) do
    Repo.all(
      from(m in OperatorMessage,
        where:
          m.provider_correlation_id == ^correlation_id and m.status in ^statuses and
            (is_nil(m.delivery) or m.delivery != "queued"),
        distinct: true,
        select: m.target_agent_id
      )
    )
  end

  defp broadcast_message_changes(updated, targets) when updated > 0 do
    Enum.each(targets, &Custode.PubSubBridge.broadcast({:operator_message_changed, &1}))
  end

  defp broadcast_message_changes(_updated, _targets), do: :ok

  defp update!(message, attrs) do
    message |> OperatorMessage.update_changeset(attrs) |> Repo.update!()
  end

  defp waiting_message(target_agent_id) do
    Repo.one(
      from(m in OperatorMessage,
        where: m.target_agent_id == ^target_agent_id and m.status == "waiting_for_input",
        order_by: [desc: m.id],
        limit: 1
      )
    )
  end

  defp correlation_of(nil), do: nil
  defp correlation_of(message), do: message.provider_correlation_id

  defp poll(message_id, deadline) do
    case get(message_id) do
      nil ->
        {:error, :not_found}

      message ->
        cond do
          OperatorMessage.settled?(message) ->
            {:ok, message, false}

          System.monotonic_time(:millisecond) >= deadline ->
            {:ok, message, true}

          true ->
            Process.sleep(25)
            poll(message_id, deadline)
        end
    end
  end

  defp caller(opts) do
    actor = Keyword.get(opts, :actor)

    case actor do
      %{kind: kind, id: id} when is_atom(kind) and is_binary(id) and id != "" ->
        {:ok, %{kind: kind, id: id}}

      nil ->
        {:ok, %{kind: :operator, id: Keyword.get(opts, :by, "operator")}}

      other ->
        {:error, {:invalid_caller, other}}
    end
  end

  defp prompt(text) do
    case text |> to_string() |> String.trim() do
      "" -> {:error, :empty}
      prompt -> {:ok, prompt}
    end
  end

  defp correlation(meta), do: meta[:correlation_id]

  defp job_correlation(meta), do: meta |> job_meta() |> Map.get("correlation_id")

  defp job_meta(%{job: %{meta: meta}}) when is_map(meta), do: meta
  defp job_meta(_meta), do: %{}

  defp gated_detail(agent_id, :waiting_for_user) do
    case Agents.status(agent_id) do
      {:ok, {:waiting_for_user, question}} -> question
      _other -> nil
    end
  end

  defp gated_detail(agent_id, :awaiting_permission) do
    case Agents.status(agent_id) do
      {:ok, {:awaiting_permission, %{description: description}}} -> description
      _other -> nil
    end
  end

  defp error_map(kind, reason),
    do: %{"kind" => to_string(kind), "detail" => inspect(reason, printable_limit: 500)}

  defp output_map(output), do: %{"output" => output}

  defp provider_name(provider),
    do: provider |> Atom.to_string() |> String.replace_prefix("oban_", "")

  defp message_id,
    do: "msg_" <> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)

  defp hash(prompt), do: :crypto.hash(:sha256, prompt) |> Base.encode16(case: :lower)
  defp now, do: DateTime.utc_now()
  defp iso8601(nil), do: nil
  defp iso8601(datetime), do: DateTime.to_iso8601(datetime)
end
