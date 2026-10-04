defmodule Custode.Assurance.Native.Events do
  @moduledoc "Native stream observations. Authored findings remain separate from tool execution."

  def observe(provider, raw) do
    decoded = raw |> String.split("\n", trim: true) |> Enum.map(&Jason.decode/1)
    events = for {:ok, %{} = event} <- decoded, do: event

    malformed =
      Enum.count(decoded, &(not match?({:ok, %{"type" => type}} when is_binary(type), &1)))

    identity = identity(provider, events)
    errors = protocol_errors(provider, events, identity, malformed)

    Map.merge(identity, %{
      "commands" =>
        for(event <- events, item = command(provider, event), not is_nil(item), do: item),
      "opinion" => opinion(provider, events),
      "malformed_lines" => malformed,
      "protocol_errors" => errors,
      "stream_sha256" => digest(raw)
    })
  end

  defp identity("claude", events) do
    terminal = single_event(events, &(&1["type"] == "result"))

    session =
      single_value(events, &(&1["type"] == "system" and &1["subtype"] == "init"), "session_id")

    %{
      "session_id" => session,
      "observed_model" =>
        single_value(events, &(&1["type"] == "system" and &1["subtype"] == "init"), "model"),
      "terminal_observed" =>
        terminal["subtype"] == "success" and terminal["is_error"] == false and
          terminal["session_id"] == session,
      "usage" => terminal["usage"],
      "cost_usd" => terminal["total_cost_usd"]
    }
  end

  defp identity("codex", events) do
    terminal = single_event(events, &(&1["type"] in ~w(turn.completed turn.failed error)))

    %{
      "session_id" => single_value(events, &(&1["type"] == "thread.started"), "thread_id"),
      "observed_model" => nil,
      "terminal_observed" => terminal["type"] == "turn.completed",
      "usage" => terminal["usage"],
      "cost_usd" => nil
    }
  end

  defp protocol_errors(provider, events, identity, malformed) do
    first = Enum.find_index(events, &identity_event?(provider, &1))
    last = Enum.find_index(events, &terminal_event?(provider, &1))

    checks = [
      {is_binary(identity["session_id"]) and String.trim(identity["session_id"]) != "",
       "missing_or_conflicting_native_identity"},
      {identity["terminal_observed"], "missing_or_conflicting_successful_terminal"},
      {malformed == 0, "non_object_or_malformed_native_line"},
      {ordered?(events, first, last), "native_event_order"},
      {valid_items?(events), "malformed_native_item"},
      {valid_command_ids?(provider, events), "missing_or_conflicting_native_command_identity"}
    ]

    for {false, error} <- checks, do: error
  end

  defp valid_items?(events) do
    Enum.all?(events, fn event ->
      event["type"] not in ~w(item.started item.completed item.updated) or is_map(event["item"])
    end)
  end

  defp valid_command_ids?(provider, events) do
    commands = for event <- events, item = command(provider, event), not is_nil(item), do: item
    ids = Enum.all?(commands, &(is_binary(&1["id"]) and String.trim(&1["id"]) != ""))

    coherent =
      commands
      |> Enum.group_by(& &1["id"])
      |> Enum.all?(fn {_id, copies} -> length(Enum.uniq(copies)) == 1 end)

    ids and coherent
  end

  defp ordered?(_events, nil, _last), do: false
  defp ordered?(_events, _first, nil), do: false

  defp ordered?(events, first, last) do
    first < last and last == length(events) - 1 and
      Enum.all?(Enum.with_index(events), fn {event, index} ->
        event["type"] not in ~w(item.completed assistant) or index > first
      end)
  end

  defp identity_event?("codex", event), do: event["type"] == "thread.started"

  defp identity_event?("claude", event),
    do: event["type"] == "system" and event["subtype"] == "init"

  defp terminal_event?("codex", event), do: event["type"] in ~w(turn.completed turn.failed error)
  defp terminal_event?("claude", event), do: event["type"] == "result"

  defp single_event(events, predicate) do
    case events |> Enum.filter(predicate) |> Enum.uniq() do
      [event] -> event
      _other -> %{}
    end
  end

  defp single_value(events, predicate, key) do
    case events |> Enum.filter(predicate) |> Enum.map(& &1[key]) |> Enum.uniq() do
      [value] -> value
      _other -> nil
    end
  end

  defp command("codex", %{
         "type" => "item.completed",
         "item" => %{"type" => "command_execution"} = item
       }),
       do: Map.take(item, ~w(id command cwd aggregated_output exit_code status))

  defp command(_provider, _event), do: nil

  defp opinion("claude", events) do
    result = single_event(events, &(&1["type"] == "result"))
    decode_opinion(result["structured_output"] || result["result"])
  end

  defp opinion("codex", events) do
    item =
      Enum.find(Enum.reverse(events), &agent_message?/1) || %{}

    decode_opinion(get_in(item, ["item", "text"]))
  end

  defp agent_message?(%{"type" => "item.completed", "item" => %{"type" => "agent_message"}}),
    do: true

  defp agent_message?(_event), do: false

  defp decode_opinion(value) when is_map(value), do: value

  defp decode_opinion(value) when is_binary(value) do
    case Jason.decode(String.trim(value)) do
      {:ok, %{} = opinion} -> opinion
      _other -> nil
    end
  end

  defp decode_opinion(_other), do: nil
  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
