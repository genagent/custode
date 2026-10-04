defmodule Custode.FeedbackAnchors do
  @moduledoc "Exact text and Git hunk selections, separate from editing or approval."
  @coordinates ~w(start_line end_line start_column end_column)
  @hunk_keys ~w(kind expected_git_revision expected_diff_revision hunk_id)
  @preview_bytes 1024
  @hunk_limit 100

  def form(params) do
    kind = params["anchor_kind"] || "lines"

    clean =
      Map.drop(params, [
        "anchor_kind",
        "hunk_id",
        "expected_git_revision",
        "expected_diff_revision" | @coordinates
      ])

    case kind do
      "lines" ->
        with {:ok, values} <- integers(params, ~w(start_line end_line)),
             do: {:ok, Map.merge(clean, values)}

      "span" ->
        with {:ok, values} <- integers(params, @coordinates),
             do: {:ok, Map.put(clean, "anchor", Map.put(values, "kind", "span"))}

      "diff_hunk" ->
        anchor = params |> Map.take(tl(@hunk_keys)) |> Map.put("kind", kind)
        {:ok, Map.put(clean, "anchor", anchor)}

      _other ->
        {:error, "invalid_feedback_anchor"}
    end
  end

  defp integers(params, keys) do
    Enum.reduce_while(keys, {:ok, %{}}, fn key, {:ok, values} ->
      case integer(params[key]) do
        {value, ""} -> {:cont, {:ok, Map.put(values, key, value)}}
        _invalid -> {:halt, {:error, "invalid_line_span"}}
      end
    end)
  end

  defp integer(value) when is_binary(value), do: Integer.parse(value)
  defp integer(_value), do: :invalid

  def source_action(%{"anchor" => %{"kind" => "diff_hunk"}}), do: "diff"
  def source_action(_params), do: "read"

  def select(params, source) do
    case {params["anchor"],
          Map.has_key?(params, "start_line") or Map.has_key?(params, "end_line")} do
      {nil, _legacy} -> lines(Map.take(params, ~w(start_line end_line)), source)
      {_anchor, true} -> {:error, "ambiguous_feedback_anchor"}
      {%{"kind" => "lines"} = anchor, false} -> lines(Map.delete(anchor, "kind"), source)
      {%{"kind" => "span"} = anchor, false} -> span(anchor, source)
      {%{"kind" => "diff_hunk"} = anchor, false} -> hunk(anchor, source)
      _invalid -> {:error, "invalid_feedback_anchor"}
    end
  end

  defp lines(%{"start_line" => first, "end_line" => last} = anchor, source) do
    rows = String.split(source["content"], "\n")

    if exact_keys?(anchor, ~w(start_line end_line)) and valid_range?(first, last, length(rows)) do
      {:ok, start} = offset(rows, first, 1)
      {:ok, finish} = offset(rows, last, String.length(row_text(rows, last)) + 1)
      text = binary_part(source["content"], start, finish - start)
      {:ok, anchor |> Map.put("kind", "lines") |> evidence(text)}
    else
      {:error, "invalid_line_span"}
    end
  end

  defp lines(_anchor, _source), do: {:error, "invalid_line_span"}

  defp span(anchor, source) do
    rows = String.split(source["content"], "\n")

    with true <- exact_keys?(anchor, ["kind" | @coordinates]),
         {:ok, first} <- offset(rows, anchor["start_line"], anchor["start_column"]),
         {:ok, last} <- offset(rows, anchor["end_line"], anchor["end_column"]),
         true <- first < last do
      text = binary_part(source["content"], first, last - first)

      {:ok,
       anchor
       |> Map.put("column_unit", "unicode_grapheme_1_based_end_exclusive")
       |> evidence(text)}
    else
      _invalid -> {:error, "invalid_text_span"}
    end
  end

  defp offset(rows, line, column)
       when is_integer(line) and is_integer(column) and line > 0 and column > 0 do
    row = row_text(rows, line)

    if is_binary(row) and column <= String.length(row) + 1 do
      before = rows |> Enum.take(line - 1) |> Enum.reduce(0, &(byte_size(&1) + 1 + &2))
      {:ok, before + byte_size(String.slice(row, 0, column - 1))}
    else
      {:error, "invalid_text_span"}
    end
  end

  defp offset(_rows, _line, _column), do: {:error, "invalid_text_span"}

  defp row_text(rows, line) do
    row = Enum.at(rows, line - 1)

    if is_binary(row) and line < length(rows) and String.ends_with?(row, "\r"),
      do: binary_part(row, 0, byte_size(row) - 1),
      else: row
  end

  def diff_view(source) do
    revision = diff_revision(source)
    hunks = parse_hunks(source, revision)

    source
    |> Map.delete("diff")
    |> Map.put("diff_revision", revision)
    |> Map.put("hunks", Enum.take(hunks, @hunk_limit))
    |> Map.put("has_more_hunks", length(hunks) > @hunk_limit)
    |> Map.put("feedback_hunk_limit", @hunk_limit)
  end

  defp hunk(anchor, source) do
    view = diff_view(source)

    cond do
      not exact_keys?(anchor, @hunk_keys) ->
        {:error, "invalid_diff_hunk_anchor"}

      anchor["expected_git_revision"] != source["git_revision"] or
          anchor["expected_diff_revision"] != view["diff_revision"] ->
        {:error, "diff_changed_reread_and_reanchor"}

      true ->
        case Enum.find(view["hunks"], &(&1["hunk_id"] == anchor["hunk_id"])) do
          nil ->
            {:error, "diff_hunk_not_current"}

          selected ->
            result =
              Map.merge(anchor, Map.take(selected, ~w(old_start old_count new_start new_count)))

            {:ok, evidence(result, selected["text"])}
        end
    end
  end

  def current_hunk?(anchor, view) do
    anchor["expected_git_revision"] == view["git_revision"] and
      anchor["expected_diff_revision"] == view["diff_revision"] and
      Enum.any?(view["hunks"], &(&1["hunk_id"] == anchor["hunk_id"]))
  end

  defp parse_hunks(source, revision) do
    source["diff"]
    |> String.split(~r/(?=^@@ )/m)
    |> Enum.filter(&String.starts_with?(&1, "@@ "))
    |> Enum.with_index(1)
    |> Enum.map(fn {text, index} ->
      [header | _body] = String.split(text, "\n", parts: 2)

      ranges =
        Regex.named_captures(
          ~r/^@@ -(?<old>\d+)(?:,(?<old_count>\d+))? \+(?<new>\d+)(?:,(?<new_count>\d+))? @@/,
          header
        )

      %{
        "hunk_id" => hash(Jason.encode!([revision, index, text])),
        "header" => header,
        "text" => text,
        "old_start" => String.to_integer(ranges["old"]),
        "old_count" => count(ranges["old_count"]),
        "new_start" => String.to_integer(ranges["new"]),
        "new_count" => count(ranges["new_count"])
      }
    end)
  end

  defp count(value) when value in [nil, ""], do: 1
  defp count(value), do: String.to_integer(value)

  defp diff_revision(source),
    do:
      hash(
        Jason.encode!(
          Enum.map(~w(revision git_revision base_revision git_blob_id diff), &source[&1])
        )
      )

  defp evidence(anchor, text) do
    preview =
      text
      |> String.graphemes()
      |> Enum.reduce_while("", fn grapheme, acc ->
        if byte_size(acc) + byte_size(grapheme) <= @preview_bytes,
          do: {:cont, acc <> grapheme},
          else: {:halt, acc}
      end)

    Map.merge(anchor, %{
      "selected_text_sha256" => hash(text),
      "selected_text_bytes" => byte_size(text),
      "selected_text_preview" => preview,
      "preview_truncated" => preview != text
    })
  end

  defp valid_range?(first, last, count),
    do: is_integer(first) and is_integer(last) and first > 0 and first <= last and last <= count

  defp exact_keys?(anchor, keys), do: Enum.sort(Map.keys(anchor)) == Enum.sort(keys)
  defp hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  def schema do
    position = %{"type" => "integer", "minimum" => 1, "maximum" => 16_385}

    revision = %{
      "type" => "string",
      "minLength" => 64,
      "maxLength" => 64,
      "pattern" => "^[0-9a-f]{64}$"
    }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["kind"],
      "properties" =>
        Map.merge(Map.new(@coordinates, &{&1, position}), %{
          "kind" => %{"type" => "string", "enum" => ~w(lines span diff_hunk)},
          "expected_git_revision" => %{
            "type" => ["string", "null"],
            "minLength" => 40,
            "maxLength" => 40,
            "pattern" => "^[0-9a-f]{40}$"
          },
          "expected_diff_revision" => revision,
          "hunk_id" => revision
        })
    }
  end
end
