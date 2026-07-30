defmodule Custode.Attention.Projection do
  @moduledoc """
  The derived operator-obligation projection across Missions and WorkItems.

  Attention is rebuilt from authoritative rows on every call. It has no table,
  acknowledgement flag, or independently mutable lifecycle:

    * an open work Gate remains visible until the Gate resolves;
    * a blocked WorkItem remains visible until its state changes;
    * the latest failed or stale OperationCall for a subject and operation
      remains visible until a later call supersedes it;
    * open legacy asks and gates remain visible until their existing stores
      resolve them.

  The projection intentionally returns obligations rather than healthy work.
  Existing per-agent rest and activity signals remain available through
  `Custode.Attention.Fleet`.

  Every item uses `custode.attention.item.v1`:

      %{
        attention_key: "work_gate:<stable-id>",
        subject: %{
          kind: "mission" | "work_item" | "legacy_agent",
          id: "<stable-id>",
          mission_id: "<stable-id>" | nil,
          work_item_id: "<stable-id>" | nil
        },
        reason: %{kind: "<stable-kind>", detail: "...", evidence: %{}},
        severity: "high" | "normal" | "low",
        age_seconds: non_neg_integer(),
        owner: %{kind: "operator", id: "operator"},
        source: %{kind: "<authoritative-store>", id: "<stable-id>", status: "..."}
      }
  """

  import Ecto.Query, only: [from: 2]

  alias Custode.{
    Asks,
    Gates,
    Mission,
    OperationCall,
    Repo,
    WorkEvent,
    WorkGate,
    WorkItem
  }

  @contract "custode.attention.item.v1"
  @default_limit 25
  @max_limit 100
  @order ["severity:desc", "raised_at:asc", "attention_key:asc"]
  @subject_kinds ~w(mission work_item legacy_agent)
  @operation_attention_statuses ~w(failed stale)
  @lifecycle_events ~w(work_item.created work_item.transitioned work_item.reopened)
  @severity_rank %{"high" => 0, "normal" => 1, "low" => 2}

  @type page :: %{
          items: [map()],
          page: %{
            limit: pos_integer(),
            has_more: boolean(),
            next_cursor: String.t() | nil,
            order: [String.t()]
          }
        }

  @doc """
  List current Attention items with deterministic keyset pagination.

  Options may be a keyword list or string/atom-keyed map:

    * `:limit` - page size from 1 through 100;
    * `:after` - opaque cursor from the previous page;
    * `:mission_id` - include only obligations in one Mission;
    * `:subject_kind` - `mission`, `work_item`, or `legacy_agent`;
    * `:include_legacy` - include open legacy asks and gates, default `true`;
    * `:now` - explicit clock for deterministic callers and tests.
  """
  @spec list(keyword() | map()) :: {:ok, page()} | {:error, term()}
  def list(options \\ []) do
    with {:ok, options} <-
           options(options,
             limit: @default_limit,
             after: nil,
             mission_id: nil,
             subject_kind: nil,
             include_legacy: true,
             now: nil
           ),
         :ok <- validate_limit(options[:limit]),
         :ok <- validate_mission_id(options[:mission_id]),
         :ok <- validate_subject_kind(options[:subject_kind]),
         :ok <- validate_include_legacy(options[:include_legacy]),
         {:ok, now} <- validate_now(options[:now]),
         scope = cursor_scope(options),
         {:ok, cursor} <- decode_cursor(options[:after], scope) do
      items =
        now
        |> project(options)
        |> filter_after(cursor)

      {visible, page} = page(items, options[:limit], scope)
      {:ok, %{items: visible, page: page}}
    end
  end

  defp project(now, options) do
    subjects = subjects()

    [
      work_gate_items(now),
      blocked_work_item_items(now),
      operation_call_items(now, subjects),
      legacy_items(now, options[:include_legacy])
    ]
    |> List.flatten()
    |> Enum.filter(&in_scope?(&1, options))
    |> Enum.uniq_by(& &1.attention_key)
    |> Enum.sort_by(&sort_key/1)
  end

  defp work_gate_items(now) do
    from(gate in WorkGate,
      where: gate.status == "open",
      preload: [:mission, :work_item]
    )
    |> Repo.all()
    |> Enum.map(fn gate ->
      detail =
        map_value(gate.preview, "summary") ||
          map_value(gate.preview, "description") ||
          "operator decision required for #{gate.operation}"

      item(
        "work_gate:#{gate.gate_id}",
        work_item_subject(gate.work_item, gate.mission),
        {gate.mission.mission_id, gate.work_item.work_item_id},
        {"gate.open", detail, "high"},
        %{
          kind: "work_gate",
          id: gate.gate_id,
          status: gate.status,
          operation: gate.operation
        },
        gate.inserted_at,
        now
      )
    end)
  end

  defp blocked_work_item_items(now) do
    work_items =
      from(work_item in WorkItem,
        where: work_item.state == "blocked",
        preload: [:mission]
      )
      |> Repo.all()

    transitions = blocked_transitions(work_items)

    Enum.map(work_items, fn work_item ->
      {reason_kind, detail} = blocked_reason(work_item.blocked_reason)
      transition = Map.get(transitions, work_item.id)

      item(
        "work_item:#{work_item.work_item_id}:blocked",
        work_item_subject(work_item, work_item.mission),
        {work_item.mission.mission_id, work_item.work_item_id},
        {reason_kind, detail, "high"},
        %{
          kind: "work_item",
          id: work_item.work_item_id,
          status: work_item.state,
          version: work_item.version,
          transition_event_id: transition && transition.event_id
        },
        (transition && transition.inserted_at) || work_item.updated_at,
        now,
        evidence: work_item.blocked_reason || %{}
      )
    end)
  end

  defp blocked_transitions([]), do: %{}

  defp blocked_transitions(work_items) do
    work_item_ids = Enum.map(work_items, & &1.id)

    from(event in WorkEvent,
      where:
        event.work_item_id in ^work_item_ids and event.kind in ^@lifecycle_events and
          event.after_state == "blocked",
      order_by: [asc: event.inserted_at, asc: event.id]
    )
    |> Repo.all()
    |> Map.new(&{&1.work_item_id, &1})
  end

  defp operation_call_items(now, subjects) do
    from(call in OperationCall,
      where: not is_nil(call.mission_id) or not is_nil(call.work_item_id),
      order_by: [asc: call.inserted_at, asc: call.id]
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn call, latest ->
      case operation_subject(call, subjects) do
        nil ->
          latest

        {subject, mission_id, work_item_id} ->
          Map.put(
            latest,
            {subject.kind, subject.id, call.operation},
            {call, subject, mission_id, work_item_id}
          )
      end
    end)
    |> Map.values()
    |> Enum.filter(fn {call, _subject, _mission_id, _work_item_id} ->
      call.status in @operation_attention_statuses
    end)
    |> Enum.reject(&covered_by_blocked_work?(&1, subjects))
    |> Enum.map(fn {call, subject, mission_id, work_item_id} ->
      {reason_kind, headline} =
        case call.status do
          "stale" ->
            {"external_state.stale", "#{call.operation} is stale"}

          "failed" ->
            {"operation.failed", "#{call.operation} failed"}
        end

      item(
        "operation_call:#{call.call_id}",
        subject,
        {mission_id, work_item_id},
        {reason_kind, operation_detail(call), "normal"},
        %{
          kind: "operation_call",
          id: call.call_id,
          status: call.status,
          operation: call.operation
        },
        call.finished_at || call.inserted_at,
        now,
        headline: headline,
        evidence: call.error || %{}
      )
    end)
  end

  defp covered_by_blocked_work?(
         {call, _subject, _mission_id, work_item_id},
         subjects
       )
       when is_binary(work_item_id) do
    expected_reason =
      if call.status == "stale", do: "external_state.stale", else: "operation.failed"

    case Map.get(subjects.work_items, work_item_id) do
      %WorkItem{state: "blocked", blocked_reason: reason} ->
        blocked_reason_kind(map_value(reason, "code")) == expected_reason

      _other ->
        false
    end
  end

  defp covered_by_blocked_work?(_entry, _subjects), do: false

  defp legacy_items(_now, false), do: []

  defp legacy_items(now, true) do
    legacy_asks(now) ++ legacy_gates(now)
  end

  defp legacy_asks(now) do
    from(ask in Asks.Ask, where: ask.status == "open")
    |> Repo.all()
    |> Enum.map(fn ask ->
      item(
        "legacy_ask:#{ask.id}",
        subject("legacy_agent", ask.agent_id, nil, nil),
        {nil, nil},
        {"legacy.ask.open", ask.question, "high"},
        %{kind: "legacy_ask", id: to_string(ask.id), status: ask.status},
        ask.inserted_at,
        now,
        compatibility: %{legacy: true, authoritative_store: "asks"}
      )
    end)
  end

  defp legacy_gates(now) do
    from(gate in Gates.Gate, where: gate.status == "open")
    |> Repo.all()
    |> Enum.map(fn gate ->
      reason_kind =
        if gate.kind == "question", do: "legacy.question.open", else: "legacy.gate.open"

      item(
        "legacy_gate:#{gate.id}",
        subject("legacy_agent", gate.agent_id, nil, nil),
        {nil, nil},
        {reason_kind, gate.detail || "legacy #{gate.kind} requires operator attention", "high"},
        %{kind: "legacy_gate", id: to_string(gate.id), status: gate.status},
        gate.inserted_at,
        now,
        compatibility: %{legacy: true, authoritative_store: "gates"}
      )
    end)
  end

  defp subjects do
    missions =
      Mission
      |> Repo.all()
      |> Map.new(&{&1.mission_id, &1})

    work_items =
      from(work_item in WorkItem, preload: [:mission])
      |> Repo.all()
      |> Map.new(&{&1.work_item_id, &1})

    %{missions: missions, work_items: work_items}
  end

  defp operation_subject(%{work_item_id: work_item_id}, subjects)
       when is_binary(work_item_id) do
    case Map.get(subjects.work_items, work_item_id) do
      nil ->
        nil

      work_item ->
        {
          work_item_subject(work_item, work_item.mission),
          work_item.mission.mission_id,
          work_item.work_item_id
        }
    end
  end

  defp operation_subject(%{mission_id: mission_id}, subjects) when is_binary(mission_id) do
    case Map.get(subjects.missions, mission_id) do
      nil ->
        nil

      mission ->
        {subject("mission", mission.mission_id, mission.mission_id, nil), mission.mission_id, nil}
    end
  end

  defp operation_subject(_call, _subjects), do: nil

  defp work_item_subject(work_item, mission) do
    subject("work_item", work_item.work_item_id, mission.mission_id, work_item.work_item_id)
  end

  defp subject(kind, id, mission_id, work_item_id) do
    %{
      kind: kind,
      id: id,
      mission_id: mission_id,
      work_item_id: work_item_id
    }
  end

  defp blocked_reason(reason) do
    reason = reason || %{}
    code = map_value(reason, "code")

    kind = blocked_reason_kind(code)
    detail = map_value(reason, "detail") || default_blocked_detail(kind, code)
    {kind, detail}
  end

  defp blocked_reason_kind("repair_policy_exhausted"), do: "repair_policy.exhausted"
  defp blocked_reason_kind("operation_failed"), do: "operation.failed"

  defp blocked_reason_kind(code) do
    if stale_code?(code), do: "external_state.stale", else: "work_item.blocked"
  end

  defp default_blocked_detail("repair_policy.exhausted", _code),
    do: "repair policy is exhausted"

  defp default_blocked_detail("operation.failed", _code), do: "an operation failed"

  defp default_blocked_detail("external_state.stale", _code),
    do: "external state invalidated the planned action"

  defp default_blocked_detail("work_item.blocked", code),
    do: humanize(code) || "work is explicitly blocked"

  defp stale_code?(code) when is_binary(code),
    do: String.contains?(code, "stale") or String.contains?(code, "changed")

  defp stale_code?(_code), do: false

  defp operation_detail(call) do
    map_value(call.error, "message") ||
      map_value(call.error, "reason") ||
      map_value(call.error, "kind") ||
      "#{call.operation} ended with status #{call.status}"
  end

  defp humanize(nil), do: nil
  defp humanize(code), do: String.replace(code, "_", " ")

  defp item(
         attention_key,
         subject,
         {mission_id, work_item_id},
         {reason_kind, detail, severity},
         source,
         raised_at,
         now,
         options \\ []
       ) do
    %{
      contract: @contract,
      attention_key: attention_key,
      subject: subject,
      mission_id: mission_id,
      work_item_id: work_item_id,
      reason: %{
        kind: reason_kind,
        detail: detail,
        evidence: Keyword.get(options, :evidence, %{})
      },
      severity: severity,
      age_seconds: max(DateTime.diff(now, raised_at), 0),
      owner: %{kind: "operator", id: "operator"},
      source: source,
      headline: Keyword.get(options, :headline, detail),
      raised_at: DateTime.to_iso8601(raised_at),
      compatibility:
        Keyword.get(options, :compatibility, %{
          legacy: false,
          authoritative_store: source.kind
        })
    }
  end

  defp in_scope?(item, options) do
    mission_match? =
      is_nil(options[:mission_id]) or item.mission_id == options[:mission_id]

    subject_match? =
      is_nil(options[:subject_kind]) or item.subject.kind == options[:subject_kind]

    mission_match? and subject_match?
  end

  defp sort_key(item) do
    {Map.fetch!(@severity_rank, item.severity), item.raised_at, item.attention_key}
  end

  defp filter_after(items, nil), do: items

  defp filter_after(items, cursor) do
    Enum.drop_while(items, &(sort_key(&1) <= cursor))
  end

  defp page(items, limit, scope) do
    has_more = length(items) > limit
    visible = Enum.take(items, limit)

    next_cursor =
      if has_more do
        visible
        |> List.last()
        |> encode_cursor(scope)
      end

    {visible,
     %{
       limit: limit,
       has_more: has_more,
       next_cursor: next_cursor,
       order: @order
     }}
  end

  defp encode_cursor(item, scope) do
    %{
      "resource" => "attention",
      "severity" => item.severity,
      "raised_at" => item.raised_at,
      "attention_key" => item.attention_key,
      "scope" => scope
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil, _scope), do: {:ok, nil}

  defp decode_cursor(cursor, scope) when is_binary(cursor) do
    with {:ok, encoded} <- Base.url_decode64(cursor, padding: false),
         {:ok,
          %{
            "resource" => "attention",
            "severity" => severity,
            "raised_at" => raised_at,
            "attention_key" => attention_key,
            "scope" => ^scope
          }} <- Jason.decode(encoded),
         true <- Map.has_key?(@severity_rank, severity),
         true <- nonempty_binary?(attention_key),
         {:ok, _parsed, 0} <- DateTime.from_iso8601(raised_at) do
      {:ok, {Map.fetch!(@severity_rank, severity), raised_at, attention_key}}
    else
      _invalid -> {:error, {:invalid_cursor, cursor}}
    end
  end

  defp decode_cursor(cursor, _scope), do: {:error, {:invalid_cursor, cursor}}

  defp cursor_scope(options) do
    %{
      "mission_id" => options[:mission_id],
      "subject_kind" => options[:subject_kind],
      "include_legacy" => options[:include_legacy]
    }
  end

  defp options(options, defaults) when is_map(options) do
    known_keys = Keyword.keys(defaults)

    options
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, normalized} ->
      case option_key(key, known_keys) do
        {:ok, normalized_key} ->
          {:cont, {:ok, [{normalized_key, value} | normalized]}}

        :error ->
          {:halt, {:error, {:invalid_options, [key]}}}
      end
    end)
    |> case do
      {:ok, normalized} -> options(normalized, defaults)
      {:error, _reason} = error -> error
    end
  end

  defp options(options, defaults) when is_list(options) do
    case Keyword.validate(options, defaults) do
      {:ok, validated} -> {:ok, validated}
      {:error, unknown} -> {:error, {:invalid_options, unknown}}
    end
  end

  defp options(_options, _defaults), do: {:error, {:invalid_options, :expected_keyword_or_map}}

  defp option_key(key, known_keys) when is_atom(key) do
    if key in known_keys, do: {:ok, key}, else: :error
  end

  defp option_key(key, known_keys) when is_binary(key) do
    case Enum.find(known_keys, &(Atom.to_string(&1) == key)) do
      nil -> :error
      known_key -> {:ok, known_key}
    end
  end

  defp option_key(_key, _known_keys), do: :error

  defp validate_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: :ok
  defp validate_limit(limit), do: {:error, {:invalid_limit, limit}}

  defp validate_mission_id(nil), do: :ok
  defp validate_mission_id(value) when is_binary(value) and value != "", do: :ok
  defp validate_mission_id(value), do: {:error, {:invalid_mission_id, value}}

  defp validate_subject_kind(nil), do: :ok
  defp validate_subject_kind(value) when value in @subject_kinds, do: :ok
  defp validate_subject_kind(value), do: {:error, {:invalid_subject_kind, value}}

  defp validate_include_legacy(value) when is_boolean(value), do: :ok
  defp validate_include_legacy(value), do: {:error, {:invalid_include_legacy, value}}

  defp validate_now(nil), do: {:ok, DateTime.utc_now()}
  defp validate_now(%DateTime{} = now), do: {:ok, now}
  defp validate_now(value), do: {:error, {:invalid_now, value}}

  defp map_value(map, key) when is_map(map) do
    Map.get(map, key) ||
      Enum.find_value(map, fn
        {atom_key, value} when is_atom(atom_key) ->
          if Atom.to_string(atom_key) == key, do: value

        _entry ->
          nil
      end)
  end

  defp map_value(_map, _key), do: nil
  defp nonempty_binary?(value), do: is_binary(value) and value != ""
end
