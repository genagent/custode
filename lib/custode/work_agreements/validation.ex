defmodule Custode.WorkAgreements.Validation do
  @moduledoc false

  @max_payload_bytes 65_536
  @max_integer 9_223_372_036_854_775_807
  @reference_kinds ~w(operator_message peer_message helper_epoch report document assurance github url other)
  @resolver_kinds ~w(operator routine external)
  @outcomes ~w(accepted changes_requested rejected)

  def mutation(action, value) do
    with {:ok, attrs} <- normalize(value),
         true <- is_map(attrs),
         {:ok, encoded} <- Jason.encode(attrs),
         true <- byte_size(encoded) <= @max_payload_bytes,
         true <- valid_mutation?(action, attrs),
         normalized = defaults(action, attrs),
         {:ok, encoded} <- Jason.encode(normalized),
         true <- byte_size(encoded) <= @max_payload_bytes do
      {:ok, normalized}
    else
      _ -> {:error, :invalid_arguments}
    end
  end

  def options(opts, cursor) when is_list(opts) do
    if Keyword.keyword?(opts) and length(opts) == length(Keyword.keys(opts) |> Enum.uniq()) and
         Enum.all?(Keyword.keys(opts), &(&1 in [:limit, cursor])) do
      limit = Keyword.get(opts, :limit, 20)
      before = Keyword.get(opts, cursor)

      if is_integer(limit) and limit in 1..100 and valid_cursor?(cursor, before),
        do: {:ok, %{limit: limit, before: before}},
        else: {:error, :invalid_arguments}
    else
      {:error, :invalid_arguments}
    end
  end

  def options(_opts, _cursor), do: {:error, :invalid_arguments}

  def id?(value), do: text?(value, 160)

  defp valid_cursor?(_cursor, nil), do: true
  defp valid_cursor?(:before_sequence, value), do: positive?(value)
  defp valid_cursor?(:before_id, value), do: id?(value)

  defp valid_mutation?(:create, attrs) do
    fields?(attrs, ~w(request_id routine_id intent)) and id?(attrs["request_id"]) and
      id?(attrs["routine_id"]) and intent?(attrs["intent"])
  end

  defp valid_mutation?(:revise, attrs) do
    fields?(attrs, ~w(request_id expected_revision intent)) and id?(attrs["request_id"]) and
      positive?(attrs["expected_revision"]) and intent?(attrs["intent"])
  end

  defp valid_mutation?(:checkpoint, attrs) do
    fields?(attrs, ~w(request_id expected_revision summary), ~w(next_steps blockers decisions)) and
      id?(attrs["request_id"]) and positive?(attrs["expected_revision"]) and
      text?(attrs["summary"], 2000) and
      entries?(Map.get(attrs, "next_steps", []), &step?/1) and
      entries?(Map.get(attrs, "blockers", []), &obligation?/1) and
      entries?(Map.get(attrs, "decisions", []), &obligation?/1)
  end

  defp valid_mutation?(:submit, attrs) do
    fields?(
      attrs,
      ~w(request_id agreement_revision assignment_id summary criterion_evidence verification_limits),
      ~w(outputs)
    ) and id?(attrs["request_id"]) and positive?(attrs["agreement_revision"]) and
      id?(attrs["assignment_id"]) and text?(attrs["summary"], 2000) and
      references?(Map.get(attrs, "outputs", [])) and
      list?(attrs["criterion_evidence"], &evidence?/1, 1) and
      unique?(attrs["criterion_evidence"], "criterion_id") and
      text?(attrs["verification_limits"], 2000)
  end

  defp valid_mutation?(:resolve, attrs) do
    fields?(attrs, ~w(request_id expected_revision submission_id outcome reason)) and
      id?(attrs["request_id"]) and positive?(attrs["expected_revision"]) and
      id?(attrs["submission_id"]) and attrs["outcome"] in @outcomes and
      text?(attrs["reason"], 2000)
  end

  defp valid_mutation?(_action, _attrs), do: false

  defp intent?(intent) do
    fields?(
      intent,
      ~w(outcome criteria assignment_id),
      ~w(boundaries request_references inputs expected_outputs)
    ) and
      text?(intent["outcome"], 2000) and id?(intent["assignment_id"]) and
      list?(intent["criteria"], &criterion?/1, 1) and unique?(intent["criteria"], "id") and
      list?(Map.get(intent, "boundaries", []), &text?(&1, 2000)) and
      Enum.all?(~w(request_references inputs expected_outputs), fn key ->
        references?(Map.get(intent, key, []))
      end)
  end

  defp criterion?(value) do
    fields?(value, ~w(id text)) and id?(value["id"]) and text?(value["text"], 2000)
  end

  defp step?(value) do
    fields?(value, ~w(id text), ~w(references)) and id?(value["id"]) and
      text?(value["text"], 2000) and references?(Map.get(value, "references", []))
  end

  defp obligation?(value) do
    fields?(value, ~w(id text resolver), ~w(references)) and id?(value["id"]) and
      text?(value["text"], 2000) and resolver?(value["resolver"]) and
      references?(Map.get(value, "references", []))
  end

  defp resolver?(value) do
    fields?(value, ~w(kind id)) and value["kind"] in @resolver_kinds and id?(value["id"])
  end

  defp evidence?(value) do
    fields?(value, ~w(criterion_id references note)) and id?(value["criterion_id"]) and
      references?(value["references"]) and text?(value["note"], 2000)
  end

  defp reference?(value) do
    fields?(value, ~w(kind value), ~w(revision label)) and value["kind"] in @reference_kinds and
      text?(value["value"], 2048) and optional_text?(value, "revision", 160) and
      optional_text?(value, "label", 200)
  end

  defp references?(values), do: list?(values, &reference?/1)
  defp entries?(values, check), do: list?(values, check) and unique?(values, "id")

  defp unique?(values, key) do
    ids = Enum.map(values, &Map.fetch!(&1, key))
    length(ids) == length(Enum.uniq(ids))
  end

  defp list?(value, check, minimum \\ 0)

  defp list?(value, check, minimum) when is_list(value),
    do: length(value) in minimum..20 and Enum.all?(value, check)

  defp list?(_value, _check, _minimum), do: false

  defp optional_text?(value, key, maximum),
    do: not Map.has_key?(value, key) or text?(Map.get(value, key), maximum)

  defp text?(value, maximum) when is_binary(value),
    do: String.valid?(value) and String.trim(value) != "" and String.length(value) <= maximum

  defp text?(_value, _maximum), do: false
  defp positive?(value), do: is_integer(value) and value > 0 and value <= @max_integer

  defp fields?(value, required, optional \\ [])

  defp fields?(value, required, optional) when is_map(value),
    do:
      Enum.all?(required, &Map.has_key?(value, &1)) and
        Enum.all?(Map.keys(value), &(&1 in (required ++ optional)))

  defp fields?(_value, _required, _optional), do: false

  defp defaults(action, attrs) when action in [:create, :revise] do
    Map.update!(attrs, "intent", fn intent ->
      Enum.reduce(~w(boundaries request_references inputs expected_outputs), intent, fn key,
                                                                                        acc ->
        Map.put_new(acc, key, [])
      end)
    end)
  end

  defp defaults(:checkpoint, attrs) do
    Enum.reduce(~w(next_steps blockers decisions), attrs, fn key, acc ->
      Map.update(
        acc,
        key,
        [],
        &Enum.map(&1, fn entry -> Map.put_new(entry, "references", []) end)
      )
    end)
  end

  defp defaults(:submit, attrs), do: Map.put_new(attrs, "outputs", [])
  defp defaults(_action, attrs), do: attrs

  # Only keys are normalized. A caller cannot pass a role atom, a struct or
  # colliding atom/string keys and have it silently become a valid request.
  defp normalize(%_{}), do: {:error, :invalid_arguments}

  defp normalize(value) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, entry}, {:ok, acc} ->
      normalized_key = if is_atom(key), do: Atom.to_string(key), else: key

      with true <- is_binary(normalized_key),
           false <- Map.has_key?(acc, normalized_key),
           {:ok, normalized} <- normalize(entry) do
        {:cont, {:ok, Map.put(acc, normalized_key, normalized)}}
      else
        _ -> {:halt, {:error, :invalid_arguments}}
      end
    end)
  end

  defp normalize(value) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn entry, {:ok, acc} ->
      case normalize(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp normalize(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(_value), do: {:error, :invalid_arguments}
end
