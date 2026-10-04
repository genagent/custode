defmodule Custode.PeerMessages do
  @moduledoc """
  Durable peer mail, scoped to authenticated routine participants.

  Delivery and explicit receipt are separate from the outcome of requested
  work. Messages never grant the recipient additional authority.

  Limits may be configured with `:peer_message_limits`, a keyword list using
  the keys below. Trusted callers may inject `:limits`, `:now` and `:enqueue`
  through options. MCP callers cannot supply those options.
  """

  import Ecto.Query, only: [from: 2]
  import Kernel, except: [send: 2]

  alias Custode.{AgentHandoff, Feed, PeerMessage, PeerMessageJob, Repo, Routine}

  @limits [
    subject_chars: 200,
    body_bytes: 32_768,
    key_chars: 128,
    sender_per_hour: 30,
    max_depth: 8,
    max_correlation_messages: 24
  ]
  @send_fields [:recipient, :kind, :subject, :body, :idempotency_key]
  @reply_fields [:subject, :body, :idempotency_key]
  @payload_fields [:sender, :recipient, :kind, :subject, :body, :reply_to]
  @view_fields [
    :id,
    :sender,
    :recipient,
    :kind,
    :subject,
    :body,
    :reply_to,
    :correlation_id,
    :depth,
    :delivery_state,
    :error
  ]

  @doc "Accept a request or FYI and its delivery job atomically."
  @spec send(map(), map(), keyword()) :: {:ok, PeerMessage.t()} | {:error, term()}
  def send(identity, attrs, opts \\ []) do
    with {:ok, sender} <- writer(identity),
         {:ok, attrs} <- normalize(attrs, @send_fields),
         :ok <- kind(attrs.kind, ~w(request fyi)) do
      attrs = Map.merge(attrs, %{sender: sender, reply_to: nil, depth: 0})
      transact(fn -> accept(attrs, opts) end)
    end
  end

  @doc "Reply as the recipient of an existing message, retaining its root correlation."
  @spec reply(map(), String.t(), map(), keyword()) :: {:ok, PeerMessage.t()} | {:error, term()}
  def reply(identity, original_id, attrs, opts \\ []) do
    with {:ok, sender} <- writer(identity),
         {:ok, original_id} <- uuid(original_id),
         {:ok, attrs} <- normalize(attrs, @reply_fields) do
      transact(fn -> reply_to(sender, original_id, attrs, opts) end)
    end
  end

  @doc "Read one envelope without changing its receipt or delivery state."
  @spec read(map(), String.t()) :: {:ok, PeerMessage.t()} | {:error, term()}
  def read(identity, id) do
    with {:ok, scope} <- reader(identity),
         {:ok, id} <- uuid(id),
         %PeerMessage{} = message <- Repo.get(PeerMessage, id),
         true <- visible?(message, scope) do
      {:ok, message}
    else
      nil -> {:error, :not_found}
      false -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  List visible messages, newest first, without acknowledging them.

  Options: `:direction` (`:all`, `:inbox`, `:sent`), `:participant` (operator
  filter), `:counterpart`, `:correlation_id`, `:limit` (1..100, default 50),
  and `:offset` (0..10000, default 0). Equal timestamps sort by stable id.
  """
  @spec list(map(), keyword()) :: {:ok, [PeerMessage.t()]} | {:error, term()}
  def list(identity, opts \\ []) do
    with {:ok, scope} <- reader(identity),
         {:ok, filters} <- filters(scope, opts) do
      query =
        from(m in PeerMessage,
          order_by: [desc: m.inserted_at, desc: m.id],
          limit: ^filters.limit,
          offset: ^filters.offset
        )

      rows =
        query
        |> participant(filters.participant, filters.direction)
        |> counterpart(filters.participant, filters.counterpart)
        |> correlation(filters.correlation_id)
        |> Repo.all()

      {:ok, rows}
    end
  end

  @doc "Explicitly acknowledge receipt and queue the inbox filing projection."
  @spec acknowledge(map(), String.t(), keyword()) :: {:ok, PeerMessage.t()} | {:error, term()}
  def acknowledge(identity, id, opts \\ []) do
    with {:ok, recipient} <- writer(identity),
         {:ok, id} <- uuid(id) do
      transact(fn ->
        message = fetch!(id)
        recipient!(message, recipient)
        acknowledge_message(message, opts)
      end)
    end
  end

  @doc false
  def note_id(name) when is_binary(name) do
    with [_, id] <- Regex.run(~r/\Apeer-([0-9a-f-]{36})\.md\z/i, name),
         {:ok, id} <- uuid(id) do
      {:ok, id}
    else
      _not_a_peer_note -> :error
    end
  end

  def note_id(_name), do: :error

  @doc "Authorize a peer projection before legacy inbox reads or filing."
  def authorize_note(identity, routine_id, name, action) when action in [:read, :file] do
    case note_id(name) do
      {:ok, id} -> authorize_peer_note(identity, routine_id, id, action)
      :error -> :ok
    end
  end

  defp authorize_peer_note(identity, routine_id, id, :read) do
    case read(identity, id) do
      {:ok, %{recipient: ^routine_id}} -> :ok
      _missing_or_invisible -> {:error, :unauthorized}
    end
  end

  defp authorize_peer_note(identity, routine_id, id, :file) do
    with {:ok, ^routine_id} <- writer(identity),
         %PeerMessage{recipient: ^routine_id} <- Repo.get(PeerMessage, id) do
      :ok
    else
      _not_the_recipient -> {:error, :unauthorized}
    end
  end

  @doc false
  def acknowledge_note(routine_id, name) when is_binary(routine_id) and is_binary(name) do
    with {:ok, id} <- note_id(name),
         %PeerMessage{recipient: ^routine_id} <- Repo.get(PeerMessage, id) do
      case acknowledge(%{kind: :routine, id: routine_id}, id) do
        {:ok, _message} -> :ok
        {:error, _reason} = error -> error
      end
    else
      _not_a_peer_note -> :ok
    end
  end

  def acknowledge_note(_routine_id, _name), do: :ok

  @doc "A JSON-safe envelope without its private retry key."
  @spec view(PeerMessage.t()) :: map()
  def view(%PeerMessage{} = message) do
    Enum.reduce(
      [:inserted_at, :updated_at, :delivered_at, :acknowledged_at],
      Map.take(message, @view_fields),
      fn field, view -> Map.put(view, field, iso8601(Map.get(message, field))) end
    )
  end

  defp writer(%{kind: :routine, id: id}) when is_binary(id) and id != "" do
    case AgentHandoff.authorization_routine(id) do
      {:ok, %{id: ^id}} -> {:ok, id}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :unauthorized}
    end
  end

  defp writer(_identity), do: {:error, :unauthorized}
  defp reader(%{kind: :operator}), do: {:ok, :operator}
  defp reader(identity), do: writer(identity)

  defp visible?(_message, :operator), do: true
  defp visible?(message, id), do: id in [message.sender, message.recipient]

  defp normalize(attrs, fields) when is_map(attrs) do
    known = fields ++ Enum.map(fields, &Atom.to_string/1)
    unknown = Map.keys(attrs) -- known

    if unknown == [] do
      Enum.reduce_while(fields, {:ok, %{}}, &normalize_field(&1, &2, attrs))
    else
      {:error, {:invalid_fields, Enum.sort(unknown)}}
    end
  end

  defp normalize(_attrs, _fields), do: {:error, :invalid_attributes}

  defp normalize_field(field, {:ok, normalized}, attrs) do
    value = field_value(Map.fetch(attrs, field), Map.fetch(attrs, Atom.to_string(field)))

    case value do
      {:ok, value} -> normalize_text(field, value, normalized)
      _missing_or_ambiguous -> {:halt, {:error, {:invalid_field, field}}}
    end
  end

  defp normalize_text(field, value, normalized) do
    if is_binary(value) and String.valid?(value) and String.trim(value) != "",
      do: {:cont, {:ok, Map.put(normalized, field, value)}},
      else: {:halt, {:error, {:invalid_field, field}}}
  end

  defp field_value({:ok, value}, :error), do: {:ok, value}
  defp field_value(:error, {:ok, value}), do: {:ok, value}
  defp field_value(_atom, _string), do: :error

  defp kind(value, allowed),
    do: if(value in allowed, do: :ok, else: {:error, {:invalid_field, :kind}})

  defp reply_to(sender, original_id, attrs, opts) do
    original = fetch!(original_id)
    recipient!(original, sender)

    attrs =
      Map.merge(attrs, %{
        sender: sender,
        recipient: original.sender,
        kind: "reply",
        reply_to: original.id,
        correlation_id: original.correlation_id,
        depth: original.depth + 1
      })

    accept(attrs, opts)
  end

  defp recipient!(message, recipient) do
    if message.recipient != recipient, do: Repo.rollback(:unauthorized)
  end

  defp accept(attrs, opts) do
    case Repo.get_by(PeerMessage, sender: attrs.sender, idempotency_key: attrs.idempotency_key) do
      nil -> insert_message(attrs, opts)
      existing -> duplicate(existing, attrs)
    end
  end

  defp duplicate(existing, attrs) do
    if Map.take(existing, @payload_fields) == Map.take(attrs, @payload_fields),
      do: {existing, nil},
      else: Repo.rollback(:idempotency_conflict)
  end

  defp insert_message(attrs, opts) do
    limits = limits!(opts)
    validate_message!(attrs, limits)
    now = now(opts)
    enforce_limits!(attrs, limits, now)
    id = Ecto.UUID.generate()

    attrs =
      attrs
      |> Map.put(:id, id)
      |> Map.put_new(:correlation_id, id)
      |> Map.merge(%{inserted_at: now, updated_at: now})

    message = persist!(PeerMessage.changeset(%PeerMessage{}, attrs), :insert)
    enqueue!(message, opts)
    {message, record!(message, "peer_message_sent", message.sender)}
  end

  defp validate_message!(attrs, limits) do
    cond do
      attrs.sender == attrs.recipient -> Repo.rollback(:self_message)
      is_nil(Routine.get(attrs.recipient)) -> Repo.rollback(:unknown_recipient)
      String.length(attrs.subject) > limits.subject_chars -> invalid!(:subject)
      byte_size(attrs.body) > limits.body_bytes -> invalid!(:body)
      String.length(attrs.idempotency_key) > limits.key_chars -> invalid!(:idempotency_key)
      true -> :ok
    end
  end

  defp limits!(opts) do
    configured =
      Keyword.get(opts, :limits, Application.get_env(:custode, :peer_message_limits, []))

    unless Keyword.keyword?(configured), do: Repo.rollback({:invalid_limit, :configuration})

    unknown = Keyword.keys(configured) -- Keyword.keys(@limits)
    if unknown != [], do: Repo.rollback({:invalid_limit, hd(unknown)})

    limits = Keyword.merge(@limits, configured)

    Enum.each(limits, fn {name, value} ->
      unless is_integer(value) and value > 0, do: Repo.rollback({:invalid_limit, name})
    end)

    Map.new(limits)
  end

  defp enforce_limits!(attrs, limits, now) do
    cutoff = DateTime.add(now, -3600, :second)

    count =
      Repo.aggregate(
        from(m in PeerMessage, where: m.sender == ^attrs.sender and m.inserted_at > ^cutoff),
        :count
      )

    if count >= limits.sender_per_hour, do: Repo.rollback(:rate_limited)
    if attrs.depth > limits.max_depth, do: Repo.rollback(:depth_limit)

    if root = attrs[:correlation_id] do
      count = Repo.aggregate(from(m in PeerMessage, where: m.correlation_id == ^root), :count)
      if count >= limits.max_correlation_messages, do: Repo.rollback(:correlation_limit)
    end
  end

  defp acknowledge_message(%{acknowledged_at: at} = message, _opts) when not is_nil(at),
    do: {message, nil}

  defp acknowledge_message(message, opts) do
    message =
      message
      |> PeerMessage.changeset(%{acknowledged_at: now(opts)})
      |> persist!(:update)

    enqueue!(message, opts)
    {message, record!(message, "peer_message_acknowledged", message.recipient)}
  end

  defp enqueue!(message, opts) do
    enqueue = Keyword.get(opts, :enqueue, &Oban.insert/1)

    case enqueue.(PeerMessageJob.new(%{message_id: message.id})) do
      {:ok, _job} -> :ok
      {:error, reason} -> Repo.rollback({:enqueue_failed, reason})
      other -> Repo.rollback({:enqueue_failed, {:unexpected_reply, other}})
    end
  end

  defp record!(message, event, agent) do
    summary =
      if event == "peer_message_sent",
        do: "#{message.sender} sent #{message.kind} to #{message.recipient}: #{message.subject}",
        else: "#{message.recipient} acknowledged peer message: #{message.subject}"

    case Feed.record_in_transaction(%{
           event: event,
           agent: agent,
           peer_message_id: message.id,
           correlation_id: message.correlation_id,
           sender: message.sender,
           recipient: message.recipient,
           subject: message.subject,
           summary: summary
         }) do
      {:ok, entry} -> entry
      {:error, reason} -> Repo.rollback({:feed_failed, reason})
    end
  end

  defp persist!(changeset, operation) do
    case apply(Repo, operation, [changeset]) do
      {:ok, message} -> message
      {:error, reason} -> Repo.rollback({:persist_failed, reason})
    end
  end

  defp transact(fun) do
    case Repo.transaction(fun, mode: :immediate) do
      {:ok, {message, nil}} ->
        {:ok, message}

      {:ok, {message, event}} ->
        Feed.publish_committed(event)
        {:ok, message}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch!(id) do
    case Repo.get(PeerMessage, id) do
      nil -> Repo.rollback(:not_found)
      message -> message
    end
  end

  defp filters(scope, opts) do
    filters = %{
      participant: Keyword.get(opts, :participant, if(scope == :operator, do: nil, else: scope)),
      direction: Keyword.get(opts, :direction, :all),
      limit: Keyword.get(opts, :limit, 50),
      offset: Keyword.get(opts, :offset, 0),
      counterpart: opts[:counterpart],
      correlation_id: opts[:correlation_id]
    }

    with :ok <- filter_scope(scope, filters),
         :ok <- filter_pagination(filters),
         :ok <- filter_values(filters) do
      {:ok, filters}
    end
  end

  defp filter_scope(scope, filters) do
    cond do
      scope != :operator and filters.participant != scope ->
        {:error, :unauthorized}

      filters.direction not in [:all, :inbox, :sent] ->
        {:error, {:invalid_field, :direction}}

      filters.direction != :all and is_nil(filters.participant) ->
        {:error, {:invalid_field, :participant}}

      true ->
        :ok
    end
  end

  defp filter_pagination(%{limit: limit, offset: offset}) do
    cond do
      not is_integer(limit) or limit < 1 or limit > 100 ->
        {:error, {:invalid_field, :limit}}

      not is_integer(offset) or offset < 0 or offset > 10_000 ->
        {:error, {:invalid_field, :offset}}

      true ->
        :ok
    end
  end

  defp filter_values(filters) do
    cond do
      not optional_string?(filters.participant) ->
        {:error, {:invalid_field, :participant}}

      not optional_string?(filters.counterpart) ->
        {:error, {:invalid_field, :counterpart}}

      not is_nil(filters.correlation_id) and not match?({:ok, _id}, uuid(filters.correlation_id)) ->
        {:error, {:invalid_field, :correlation_id}}

      true ->
        :ok
    end
  end

  defp participant(query, nil, _direction), do: query
  defp participant(query, id, :inbox), do: from(m in query, where: m.recipient == ^id)
  defp participant(query, id, :sent), do: from(m in query, where: m.sender == ^id)

  defp participant(query, id, :all),
    do: from(m in query, where: m.sender == ^id or m.recipient == ^id)

  defp counterpart(query, _participant, nil), do: query
  defp counterpart(query, nil, id), do: participant(query, id, :all)

  defp counterpart(query, participant, id) do
    from(m in query,
      where:
        (m.sender == ^participant and m.recipient == ^id) or
          (m.sender == ^id and m.recipient == ^participant)
    )
  end

  defp correlation(query, nil), do: query
  defp correlation(query, id), do: from(m in query, where: m.correlation_id == ^id)
  defp optional_string?(nil), do: true
  defp optional_string?(value), do: is_binary(value) and value != ""
  defp invalid!(field), do: Repo.rollback({:invalid_field, field})

  defp uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_found}
    end
  end

  defp uuid(_value), do: {:error, :not_found}
  defp now(opts), do: opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> with_usec()

  defp with_usec(%DateTime{microsecond: {value, _precision}} = now),
    do: %{now | microsecond: {value, 6}}

  defp iso8601(nil), do: nil
  defp iso8601(value), do: DateTime.to_iso8601(value)
end
