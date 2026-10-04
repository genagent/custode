defmodule Custode.ConversationTimeline do
  @moduledoc """
  Local operator conversation projection: complete exchanges and turn updates.

  Exchanges remain atomic continuation groups, anchored at their last operator
  input. Updates are anchored at their recorded completion time. The cursor
  freezes row membership in both sources; outcomes on existing rows can advance.
  Exact provider, correlation, generation and turn identity link reports to an
  exchange. Uncorrelated legacy updates remain visibly independent evidence.

  Like OperatorMessages.conversation/2, this contains full operator text.
  Callers must enforce read authority; it is not a participant MCP read.
  """

  import Ecto.Query

  alias Custode.{Feed, OperatorMessage, OperatorMessages, Repo}

  @doc "Read a bounded chronological page of conversation units."
  def page(agent, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    with true <- is_integer(limit) and limit in 1..100,
         {:ok, cursor} <- decode(opts[:before], agent) do
      Repo.transaction(fn -> read_page(agent, limit, cursor) end)
    else
      false -> {:error, :invalid_limit}
      error -> error
    end
  end

  defp read_page(agent, limit, cursor) do
    snapshots = snapshots(agent, cursor)
    groups = groups(agent, snapshots.messages) |> boundary(cursor, 0) |> take_candidates(limit)
    feeds = feeds(agent, snapshots) |> boundary(cursor, 1) |> take_candidates(limit)

    candidates =
      Enum.map(groups, &Map.put(&1, :kind, 0)) ++ Enum.map(feeds, &Map.put(&1, :kind, 1))

    selected =
      candidates |> Enum.sort_by(&sort_key/1, :desc) |> Enum.take(limit) |> Enum.reverse()

    selected_groups = Enum.filter(selected, &(&1.kind == 0))

    exchanges =
      OperatorMessages.conversation_exchanges(agent, selected_groups, snapshots.messages)

    attached = linked_reports(agent, snapshots, Enum.map(selected_groups, & &1.correlation_id))
    exchanges = Enum.map(exchanges, &Map.put(&1, :reports, Map.get(attached, &1.id, [])))
    updates = for feed <- selected, feed.kind == 1, do: update(feed)
    has_older = length(candidates) > limit

    %{
      exchanges: exchanges,
      updates: updates,
      items: items(exchanges, updates),
      before: if(has_older, do: encode(hd(selected), agent, snapshots)),
      has_older: has_older
    }
  end

  @doc "Merge loaded units without changing their stable display identity."
  def items(exchanges, updates) do
    exchange_items =
      Enum.map(exchanges, fn exchange ->
        %{
          id: "exchange-" <> exchange.id,
          kind: :exchange,
          exchange: exchange,
          at: List.last(exchange.prompts).inserted_at,
          rank: 0,
          key: exchange.last_id
        }
      end)

    linked_ids =
      for exchange <- exchanges, report <- Map.get(exchange, :reports, []), do: report.id

    update_items =
      updates
      |> Enum.reject(&(&1.id in linked_ids))
      |> Enum.map(fn update ->
        %{
          id: "update-#{update.id}",
          kind: :update,
          update: update,
          at: update.at,
          rank: 1,
          key: update.id
        }
      end)

    Enum.sort_by(
      exchange_items ++ update_items,
      &{DateTime.to_unix(&1.at, :microsecond), &1.rank, &1.key}
    )
  end

  @doc "Refresh already loaded exchanges so a late completion cannot remain stale."
  def refresh_exchanges(_agent, []), do: []

  def refresh_exchanges(agent, loaded) do
    ids = Enum.map(loaded, & &1.id)

    {:ok, exchanges} =
      Repo.transaction(fn ->
        snapshot = snapshots(agent, nil)

        selected =
          groups(agent, snapshot.messages) |> where([g], g.correlation_id in ^ids) |> Repo.all()

        attached = linked_reports(agent, snapshot, ids)

        OperatorMessages.conversation_exchanges(agent, selected, snapshot.messages)
        |> Enum.map(&Map.put(&1, :reports, Map.get(attached, &1.id, [])))
      end)

    exchanges
  end

  defp snapshots(_agent, %{snapshots: snapshots}), do: snapshots

  defp snapshots(agent, nil) do
    %{
      messages:
        Repo.one(
          from(m in OperatorMessage,
            where: m.target_agent_id == ^agent and m.caller_kind == "operator",
            select: max(m.id)
          )
        ) || 0,
      feeds:
        Repo.one(
          from(f in Feed.Entry, where: f.agent == ^agent and f.event == "turn", select: max(f.id))
        ) || 0
    }
  end

  defp groups(agent, snapshot) do
    grouped =
      from(m in OperatorMessage,
        where: m.target_agent_id == ^agent and m.caller_kind == "operator" and m.id <= ^snapshot,
        group_by: m.provider_correlation_id,
        select: %{
          correlation_id: m.provider_correlation_id,
          first_id: min(m.id),
          last_id: max(m.id),
          id: max(m.id),
          at: max(m.inserted_at)
        }
      )

    from(g in subquery(grouped))
  end

  defp matching_messages(query, agent, snapshot, qualifier) do
    join(query, qualifier, [f], m in OperatorMessage,
      on:
        m.target_agent_id == ^agent and m.caller_kind == "operator" and m.id <= ^snapshot and
          m.provider_correlation_id == fragment("json_extract(?, '$.correlation_id')", f.entry) and
          m.provider == fragment("json_extract(?, '$.provider')", f.entry) and
          m.agent_generation == fragment("json_extract(?, '$.generation')", f.entry) and
          m.agent_turn_id == fragment("json_extract(?, '$.turn_id')", f.entry)
    )
  end

  defp feeds(agent, snapshots) do
    from(f in Feed.Entry,
      where: f.agent == ^agent and f.event == "turn" and f.id <= ^snapshots.feeds
    )
    |> matching_messages(agent, snapshots.messages, :left)
    |> where([_f, m], is_nil(m.id))
    |> select([f], %{id: f.id, at: f.at, entry: f.entry})
  end

  defp linked_reports(_agent, _snapshots, []), do: %{}

  defp linked_reports(agent, snapshots, correlations) do
    from(f in Feed.Entry,
      where: f.agent == ^agent and f.event == "turn" and f.id <= ^snapshots.feeds
    )
    |> matching_messages(agent, snapshots.messages, :inner)
    |> where([_f, m], m.provider_correlation_id in ^correlations)
    |> distinct(true)
    |> order_by([f], asc: f.id)
    |> select([f, m], %{
      id: f.id,
      at: f.at,
      entry: f.entry,
      correlation_id: m.provider_correlation_id
    })
    |> Repo.all()
    |> Enum.group_by(& &1.correlation_id, &update/1)
  end

  defp take_candidates(query, limit) do
    Repo.all(from(u in query, order_by: [desc: u.at, desc: u.id], limit: ^(limit + 1)))
  end

  defp boundary(query, nil, _kind), do: query

  defp boundary(query, %{at: at, kind: kind}, rank) when rank < kind,
    do: where(query, [u], u.at <= ^at)

  defp boundary(query, %{at: at, kind: kind}, rank) when rank > kind,
    do: where(query, [u], u.at < ^at)

  defp boundary(query, %{at: at, id: id}, _rank),
    do: where(query, [u], u.at < ^at or (u.at == ^at and u.id < ^id))

  defp update(feed), do: %{id: feed.id, at: feed.at, entry: Jason.decode!(feed.entry)}
  defp sort_key(unit), do: {DateTime.to_unix(unit.at, :microsecond), unit.kind, unit.id}

  defp encode(unit, agent, snapshots) do
    %{
      resource: "conversation_timeline.v1",
      scope: agent,
      at: DateTime.to_iso8601(unit.at),
      kind: unit.kind,
      id: unit.id,
      messages: snapshots.messages,
      feeds: snapshots.feeds
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode(nil, _agent), do: {:ok, nil}

  defp decode(value, agent) when is_binary(value) and byte_size(value) <= 4096 do
    with {:ok, json} <- Base.url_decode64(value, padding: false),
         {:ok,
          %{
            "resource" => "conversation_timeline.v1",
            "scope" => ^agent,
            "at" => at,
            "kind" => kind,
            "id" => id,
            "messages" => messages,
            "feeds" => feeds
          }} <- Jason.decode(json),
         true <- valid_watermarks?(kind, id, messages, feeds),
         true <- is_binary(at) and id <= if(kind == 0, do: messages, else: feeds),
         {:ok, timestamp, 0} <- DateTime.from_iso8601(at) do
      {:ok, %{at: timestamp, kind: kind, id: id, snapshots: %{messages: messages, feeds: feeds}}}
    else
      _ -> {:error, :invalid_cursor}
    end
  end

  defp decode(_value, _agent), do: {:error, :invalid_cursor}

  defp valid_watermarks?(kind, id, messages, feeds)
       when kind in [0, 1] and is_integer(id) and is_integer(messages) and is_integer(feeds),
       do: id > 0 and messages >= 0 and feeds >= 0

  defp valid_watermarks?(_kind, _id, _messages, _feeds), do: false
end
