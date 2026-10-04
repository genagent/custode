defmodule Custode.FeedbackAnchorsTest do
  use ExUnit.Case, async: true
  alias Custode.FeedbackAnchors
  alias Snodo.Schema.Validator.Basic

  test "text spans count graphemes, include selected separators and exclude their end" do
    content = "A👨‍👩‍👧‍👦éZ\nSecond line\n"
    source = %{"content" => content}

    selector = %{
      "kind" => "span",
      "start_line" => 1,
      "start_column" => 2,
      "end_line" => 1,
      "end_column" => 4
    }

    assert {:ok, anchor} = FeedbackAnchors.select(%{"anchor" => selector}, source)
    assert anchor["selected_text_preview"] == "👨‍👩‍👧‍👦é"
    assert anchor["selected_text_sha256"] == sha("👨‍👩‍👧‍👦é")
    assert anchor["column_unit"] == "unicode_grapheme_1_based_end_exclusive"

    assert {:ok, multiline} =
             FeedbackAnchors.select(
               %{
                 "anchor" => %{selector | "start_column" => 4, "end_line" => 2, "end_column" => 3}
               },
               source
             )

    assert multiline["selected_text_preview"] == "Z\nSe"
  end

  test "CRLF line separators retain exact bytes without becoming selectable columns" do
    source = %{"content" => "A\r\nB\r\n"}

    selector = %{
      "kind" => "span",
      "start_line" => 1,
      "start_column" => 2,
      "end_line" => 2,
      "end_column" => 2
    }

    assert {:ok, anchor} = FeedbackAnchors.select(%{"anchor" => selector}, source)
    assert anchor["selected_text_preview"] == "\r\nB"

    assert {:error, "invalid_text_span"} =
             FeedbackAnchors.select(%{"anchor" => %{selector | "start_column" => 3}}, source)

    assert {:ok, line} = FeedbackAnchors.select(%{"start_line" => 1, "end_line" => 1}, source)
    assert line["selected_text_preview"] == "A"
    assert {:ok, lines} = FeedbackAnchors.select(%{"start_line" => 1, "end_line" => 2}, source)
    assert lines["selected_text_preview"] == "A\r\nB"
  end

  test "invalid, reversed, empty and mixed selections refuse" do
    source = %{"content" => "short\n"}

    valid = %{
      "kind" => "span",
      "start_line" => 1,
      "start_column" => 1,
      "end_line" => 1,
      "end_column" => 2
    }

    for invalid <- [
          Map.put(valid, "start_column", 0),
          Map.put(valid, "end_column", 9),
          Map.put(valid, "end_line", 3),
          Map.put(valid, "end_column", 1),
          Map.put(valid, "unexpected", true)
        ] do
      assert {:error, "invalid_text_span"} =
               FeedbackAnchors.select(%{"anchor" => invalid}, source)
    end

    assert {:error, "ambiguous_feedback_anchor"} =
             FeedbackAnchors.select(%{"anchor" => valid, "start_line" => 1}, source)

    assert {:error, "invalid_line_span"} = FeedbackAnchors.select(%{}, source)
    assert {:ok, lines} = FeedbackAnchors.select(%{"start_line" => 1, "end_line" => 2}, source)
    assert lines["kind"] == "lines"
    assert lines["selected_text_preview"] == "short\n"
  end

  test "retained previews are byte bounded even with a huge combining grapheme" do
    content = "a" <> String.duplicate("́", 1000)

    params = %{
      "anchor" => %{
        "kind" => "span",
        "start_line" => 1,
        "start_column" => 1,
        "end_line" => 1,
        "end_column" => 2
      }
    }

    assert {:ok, anchor} = FeedbackAnchors.select(params, %{"content" => content})
    assert anchor["preview_truncated"]
    assert anchor["selected_text_preview"] == ""
    assert anchor["selected_text_bytes"] == byte_size(content)
    assert anchor["selected_text_sha256"] == sha(content)
  end

  test "hunks retain zero/default ranges and differ by position in a bounded projection" do
    source = diff("@@ -0,0 +1 @@\n+one\n@@ -2 +3 @@\n-old\n+new\n")
    view = FeedbackAnchors.diff_view(source)
    refute Map.has_key?(view, "diff")
    assert [first, second] = view["hunks"]
    assert first["old_start"] == 0
    assert first["old_count"] == 0
    assert first["new_count"] == 1
    assert second["old_count"] == 1
    refute first["hunk_id"] == second["hunk_id"]
    many = FeedbackAnchors.diff_view(diff(String.duplicate("@@ -1 +1 @@\n-a\n+b\n", 101)))
    assert length(many["hunks"]) == 100
    assert many["has_more_hunks"]
    assert length(Enum.uniq_by(many["hunks"], & &1["hunk_id"])) == 100
  end

  test "hunk selectors require exact fingerprint and HEAD, including explicit unborn HEAD" do
    source = diff("@@ -0,0 +1 @@\n+one\n")
    view = FeedbackAnchors.diff_view(source)
    [hunk] = view["hunks"]

    selector = %{
      "kind" => "diff_hunk",
      "expected_git_revision" => nil,
      "expected_diff_revision" => view["diff_revision"],
      "hunk_id" => hunk["hunk_id"]
    }

    assert :ok = Basic.validate(selector, FeedbackAnchors.schema())
    assert {:ok, anchor} = FeedbackAnchors.select(%{"anchor" => selector}, source)
    assert FeedbackAnchors.current_hunk?(anchor, view)
    assert anchor["selected_text_preview"] == hunk["text"]
    changed = Map.put(source, "git_revision", String.duplicate("a", 40))

    assert {:error, "diff_changed_reread_and_reanchor"} =
             FeedbackAnchors.select(%{"anchor" => selector}, changed)

    assert {:error, "invalid_diff_hunk_anchor"} =
             FeedbackAnchors.select(
               %{"anchor" => Map.delete(selector, "expected_git_revision")},
               source
             )

    assert {:error, "diff_hunk_not_current"} =
             FeedbackAnchors.select(
               %{"anchor" => %{selector | "hunk_id" => String.duplicate("b", 64)}},
               source
             )
  end

  test "form parsing shares strict selection semantics without accepting numeric junk" do
    assert {:error, "invalid_line_span"} =
             FeedbackAnchors.form(%{"start_line" => 1, "end_line" => "2"})

    assert {:error, "invalid_line_span"} =
             FeedbackAnchors.form(%{"start_line" => "1junk", "end_line" => "2"})

    assert {:ok, %{"anchor" => %{"kind" => "span", "end_column" => 2}}} =
             FeedbackAnchors.form(%{
               "anchor_kind" => "span",
               "start_line" => "1",
               "end_line" => "1",
               "start_column" => "1",
               "end_column" => "2"
             })

    assert {:error, _} =
             Basic.validate(%{"kind" => "span", "start_column" => 0}, FeedbackAnchors.schema())

    assert {:error, _} =
             Basic.validate(%{"kind" => "diff_hunk", "ref" => "HEAD~1"}, FeedbackAnchors.schema())
  end

  defp diff(text),
    do: %{
      "diff" => text,
      "revision" => String.duplicate("f", 64),
      "git_revision" => nil,
      "base_revision" => nil,
      "git_blob_id" => nil
    }

  defp sha(text), do: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
end
